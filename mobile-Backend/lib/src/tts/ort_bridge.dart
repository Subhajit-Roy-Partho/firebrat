/// Dart side of `OrtBridge.kt` (channel `firebrat/ort`): ONNX Runtime sessions
/// with NNAPI flags, per-session profiling and typed-array tensors. Android only.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Bit flags for [OrtBridge.create]'s `nnapiFlags` (match OrtBridge.kt).
class NnapiFlags {
  static const int useFp16 = 1;
  static const int useNchw = 2;
  static const int cpuDisabled = 4;
  static const int cpuOnly = 8;
}

class OrtBridgeOutput {
  final String name;
  final List<int> shape;
  final Object data; // Float32List or Int64List
  const OrtBridgeOutput(this.name, this.shape, this.data);
  Float32List get floats => switch (data) {
    final Float32List f => f,
    final Uint8List h => halfBytesToFloats(h), // float16 output
    _ => throw StateError('not a float tensor'),
  };
}

class OrtBridgeSession {
  static const _channel = MethodChannel('firebrat/ort');
  final String id;
  final List<String> inputNames;
  final List<String> outputNames;
  OrtBridgeSession._(this.id, this.inputNames, this.outputNames);

  static Future<OrtBridgeSession> create(
    String path, {
    String provider = 'cpu', // cpu | xnnpack | nnapi
    int threads = 2,
    int nnapiFlags = 0,
    bool verbose = false,
    String? profilePrefix,
  }) async {
    final r = await _channel.invokeMapMethod<String, Object?>('create', {
      'path': path,
      'provider': provider,
      'threads': threads,
      'nnapiFlags': nnapiFlags,
      'verbose': verbose,
      'profilePrefix': profilePrefix,
    });
    return OrtBridgeSession._(
      r!['id'] as String,
      List<String>.from(r['inputs'] as List),
      List<String>.from(r['outputs'] as List),
    );
  }

  /// Runs the model. [inputs] values are [Int64List] or [Float32List] with [shapes].
  Future<({List<OrtBridgeOutput> outputs, double nativeMs})> run(
    Map<String, (List<int>, Object)> inputs,
  ) async {
    final r = await _channel.invokeMapMethod<String, Object?>('run', {
      'id': id,
      'inputs': [
        for (final e in inputs.entries)
          {'name': e.key, 'shape': e.value.$1, 'data': e.value.$2},
      ],
    });
    final outs = [
      for (final o in (r!['outputs'] as List))
        OrtBridgeOutput(
          (o as Map)['name'] as String,
          List<int>.from(o['shape'] as List),
          o['data']!,
        ),
    ];
    return (outputs: outs, nativeMs: (r['ms'] as num).toDouble());
  }

  /// Closes the session; returns the profile file path when profiling was on.
  Future<String?> close({bool profile = false}) async => await _channel
      .invokeMethod<String>('close', {'id': id, 'profile': profile});
}

/// IEEE half -> float (little-endian bytes), for float16 model inputs/outputs.
Float32List halfBytesToFloats(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final h = bd.getUint16(i * 2, Endian.little);
    final sign = (h >> 15) & 1, exp = (h >> 10) & 0x1f, frac = h & 0x3ff;
    double v;
    if (exp == 0) {
      v = frac * 5.960464477539063e-8; // 2^-24
    } else if (exp == 31) {
      v = frac == 0 ? double.infinity : double.nan;
    } else {
      v = (1 + frac / 1024) * _pow2(exp - 15);
    }
    out[i] = sign == 1 ? -v : v;
  }
  return out;
}

double _pow2(int e) {
  var r = 1.0;
  if (e >= 0) {
    for (var i = 0; i < e; i++) {
      r *= 2;
    }
  } else {
    for (var i = 0; i < -e; i++) {
      r /= 2;
    }
  }
  return r;
}

/// float -> IEEE half bytes (round to nearest, clamps to the half range).
Uint8List floatsToHalfBytes(Float32List values) {
  final out = Uint8List(values.length * 2);
  final bd = ByteData.sublistView(out);
  final f32 = ByteData(4);
  for (var i = 0; i < values.length; i++) {
    f32.setFloat32(0, values[i], Endian.little);
    final x = f32.getUint32(0, Endian.little);
    final sign = (x >> 16) & 0x8000;
    var exp = ((x >> 23) & 0xff) - 127 + 15;
    var man = x & 0x7fffff;
    int h;
    if (exp >= 31) {
      h = sign | 0x7bff; // clamp to max finite half (65504)
    } else if (exp <= 0) {
      if (exp < -10) {
        h = sign;
      } else {
        man |= 0x800000;
        final shift = 14 - exp;
        h = sign | ((man + (1 << (shift - 1))) >> shift);
      }
    } else {
      h = sign | (exp << 10) | ((man + 0x1000) >> 13);
    }
    bd.setUint16(i * 2, h & 0xffff, Endian.little);
  }
  return out;
}
