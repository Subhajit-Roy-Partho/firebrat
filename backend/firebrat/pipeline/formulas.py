"""LaTeX → PNG via system pdflatex + Ghostscript (+ ImageMagick trim).

Note: `standalone.cls` is not installed on this cluster's texlive, and
`pdflatex` produces a PDF (not a DVI), so dvipng is not usable here either —
the working path is pdflatex (article class) -> Ghostscript rasterization ->
ImageMagick trim to content bbox.
"""
import logging
import os
import shutil
import subprocess
import tempfile

log = logging.getLogger(__name__)

_PLACEHOLDER = "%%FIREBRAT_LATEX%%"

LATEX_TEMPLATE_ARTICLE = r"""\documentclass{article}
\usepackage{amsmath}
\usepackage{amssymb}
\usepackage{amsfonts}
\pagestyle{empty}
\begin{document}
""" + _PLACEHOLDER + r"""
\end{document}
"""


def _run(cmd: list[str], cwd: str, timeout: int = 20) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def render_latex_to_png(latex_str: str, out_path: str, dpi: int = 400) -> bool:
    """Render a LaTeX string to a tightly-cropped PNG. Returns True on success."""
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    latex_str = latex_str.strip()
    if not latex_str:
        log.warning("Empty LaTeX string, skipping render -> %s", out_path)
        return False

    if not (latex_str.startswith("$") or latex_str.startswith("\\begin")):
        latex_str = f"${latex_str}$"

    tex = LATEX_TEMPLATE_ARTICLE.replace(_PLACEHOLDER, latex_str)
    tmpdir = tempfile.mkdtemp(prefix="firebrat_latex_")
    try:
        tex_path = os.path.join(tmpdir, "formula.tex")
        with open(tex_path, "w") as f:
            f.write(tex)

        r = _run(["pdflatex", "-interaction=nonstopmode", "-halt-on-error", "formula.tex"],
                 cwd=tmpdir, timeout=30)
        pdf = os.path.join(tmpdir, "formula.pdf")
        if r.returncode != 0 or not os.path.exists(pdf):
            log.warning("pdflatex failed for %r: %s", latex_str[:120], r.stdout[-800:])
            return False

        if not shutil.which("gs"):
            log.warning("Ghostscript (gs) not found, cannot rasterize %s", pdf)
            return False

        raw_png = os.path.join(tmpdir, "raw.png")
        r2 = _run(["gs", "-dBATCH", "-dNOPAUSE", "-dSAFER", "-sDEVICE=png16m",
                   f"-r{dpi}", f"-sOutputFile={raw_png}", pdf], cwd=tmpdir, timeout=20)
        if r2.returncode != 0 or not os.path.exists(raw_png):
            log.warning("gs rasterize failed: %s", r2.stderr[:500])
            return False

        # Trim to content bbox (article class leaves large page margins)
        if shutil.which("convert"):
            r3 = _run(["convert", raw_png, "-trim", "+repage", "-bordercolor", "white",
                       "-border", "8", out_path], cwd=tmpdir, timeout=15)
            if r3.returncode == 0 and os.path.exists(out_path):
                return True
            log.warning("convert -trim failed, using untrimmed PNG: %s", r3.stderr[:300])

        shutil.copy(raw_png, out_path)
        return os.path.exists(out_path)
    except Exception as e:
        log.warning("LaTeX render exception for %r: %s", latex_str[:120], e)
        return False
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def render_all_formulas(formulas: list[dict], out_dir: str) -> dict[str, bool]:
    """formulas: list of {formula_id, latex}. Writes {formula_id}.png. Returns id->success."""
    os.makedirs(out_dir, exist_ok=True)
    results: dict[str, bool] = {}
    for f in formulas:
        fid = f["formula_id"]
        latex = f.get("latex", "")
        out_path = os.path.join(out_dir, f"{fid}.png")
        ok = render_latex_to_png(latex, out_path)
        results[fid] = ok
        if ok:
            log.info("Rendered %s", fid)
        else:
            log.warning("Failed to render %s (%r)", fid, latex[:100])
    return results
