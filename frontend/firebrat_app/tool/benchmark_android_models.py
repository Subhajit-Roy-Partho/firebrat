#!/usr/bin/env python3
"""Drive the debug-only model_benchmark.dart app; preserve output and memory samples.

Install that entry point first. Model files and the selected PDF must already be
cached on the phone. This script restarts only Firebrat, never clears its data.
"""
import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

PKG = 'com.firebrat.firebrat_app'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb', default='/opt/homebrew/bin/adb')
parser.add_argument('--models', nargs='+', required=True)
parser.add_argument('--gpu-layers', type=int, default=0)
parser.add_argument('--timeout', type=int, default=1200)
parser.add_argument('--output-dir', type=pathlib.Path, required=True)
parser.add_argument('--source-pdf', default='/data/local/tmp/firebrat-technical-example.pdf')
parser.add_argument('--source-start', default='Solution:')
parser.add_argument('--source-end', default='1 . 6 . 4')
parser.add_argument('--source-chars', type=int, default=1500)
args = parser.parse_args()
args.output_dir.mkdir(parents=True, exist_ok=True)


def adb(*parts, check=True):
    return subprocess.run([args.adb, *parts], capture_output=True, text=True,
                          check=check, timeout=40).stdout


def read_report():
    try:
        return json.loads(adb('exec-out', 'run-as', PKG, 'cat', 'files/model_benchmark.json'))
    except (subprocess.SubprocessError, ValueError):
        return None


def start_button():
    for _ in range(8):
        adb('shell', 'uiautomator', 'dump', '/sdcard/firebrat-benchmark-window.xml', check=False)
        xml = adb('exec-out', 'cat', '/sdcard/firebrat-benchmark-window.xml')
        for node in ET.fromstring(xml).iter('node'):
            if node.get('content-desc') == 'Run configured model' and node.get('enabled') == 'true':
                x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
                adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
                return
        time.sleep(2)
    raise RuntimeError('Benchmark button unavailable; unlock the phone and open Firebrat.')


for model in args.models:
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    run_dir = args.output_dir / f'{stamp}-{model}-gpu{args.gpu_layers}'
    run_dir.mkdir()
    config = {'model': model, 'gpu_layers': args.gpu_layers,
              'pdf_path': args.source_pdf, 'page_index': 0,
              'source_start': args.source_start, 'source_end': args.source_end,
              'source_chars': args.source_chars,
              'label': 'Digital Design and Computer Architecture, PDF p35 / printed p24, noise margins'}
    adb('shell', 'am', 'force-stop', PKG)
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as config_file:
        json.dump(config, config_file)
        config_file.flush()
        adb('push', config_file.name, '/data/local/tmp/firebrat-benchmark-config.json')
        adb('shell', 'run-as', PKG, 'cp', '/data/local/tmp/firebrat-benchmark-config.json',
            'files/model_benchmark_config.json')
    adb('shell', 'run-as', PKG, 'rm', '-f', 'files/model_benchmark.json')
    environment = {
        'airplane_mode': adb('shell', 'settings', 'get', 'global', 'airplane_mode_on').strip(),
        'wifi_on': adb('shell', 'settings', 'get', 'global', 'wifi_on').strip(),
        'battery_before': adb('shell', 'dumpsys', 'battery'),
        'memory_before': adb('shell', 'cat', '/proc/meminfo'),
        'config': config,
    }
    (run_dir/'environment.json').write_text(json.dumps(environment, indent=2))
    adb('shell', 'am', 'start', '-n', f'{PKG}/.MainActivity')
    time.sleep(2)
    start_button()
    started = time.monotonic()
    last = None
    samples = []
    result = None
    print(f'START {model} GPU={args.gpu_layers} -> {run_dir}', flush=True)
    while time.monotonic() - started < args.timeout:
        report = read_report()
        memory = adb('shell', 'dumpsys', 'meminfo', PKG, check=False)
        sample = {'elapsed_s': round(time.monotonic()-started, 3)}
        for label in ('PSS', 'RSS', 'SWAP PSS'):
            found = re.search(r'TOTAL '+label+r':\s*(\d+)', memory)
            if found:
                sample[label.lower().replace(' ', '_')+'_kib'] = int(found.group(1))
        samples.append(sample)
        (run_dir/'memory.json').write_text(json.dumps(samples, indent=2))
        if report:
            (run_dir/'latest.json').write_text(json.dumps(report, indent=2))
            progress = (report.get('stage'), report.get('detail'))
            if progress != last:
                print(f'{model} {sample["elapsed_s"]:.0f}s {progress}', flush=True)
                last = progress
            if report.get('stage') in ('complete', 'error') and 'generation' in report:
                result = report
                break
        if not adb('shell', 'pidof', PKG, check=False).strip():
            result = report or {}
            result['stage'] = 'process_exit'
            result['android_exit_info'] = adb('shell', 'dumpsys', 'activity', 'exit-info', PKG)
            break
        time.sleep(5)
    if result is None:
        result = read_report() or {}
        result['host_timeout_s'] = args.timeout
        result['stage'] = 'timeout'
        adb('shell', 'am', 'force-stop', PKG)
    result['host_measurements'] = {
        'peak_pss_kib': max((s.get('pss_kib', 0) for s in samples), default=0),
        'peak_rss_kib': max((s.get('rss_kib', 0) for s in samples), default=0),
        'samples': len(samples), 'interval_target_s': 5,
        'wall_s': round(time.monotonic()-started, 3),
        'battery_after': adb('shell', 'dumpsys', 'battery'),
    }
    if result.get('source_text'):
        result['source_sha256'] = hashlib.sha256(result['source_text'].encode()).hexdigest()
    (run_dir/'result.json').write_text(json.dumps(result, indent=2))
    print(f'END {model}: {result.get("stage")} {result.get("generation")} '
          f'peakPSS={result["host_measurements"]["peak_pss_kib"]} KiB', flush=True)
