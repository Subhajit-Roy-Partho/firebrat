# Firebrat marketing site

Source of truth for [firebrat.github.io](https://subhajit-roy-partho.github.io/firebrat/) lives here, on `master`. The deployed copy lives on the orphan `gh-pages` branch (GitHub Pages serves from `gh-pages:/`), which is a **mirror**, not a place to edit directly.

Static HTML/CSS/JS, no build step, no framework — three pages (`index.html`, `about.html`, `architecture.html`) sharing `assets/styles.css` and `assets/main.js`.

## Redeploying after an edit

```bash
git worktree add /tmp/firebrat-ghpages gh-pages
cp -r site/* /tmp/firebrat-ghpages/
cd /tmp/firebrat-ghpages
git add -A
git commit -m "Update site"
git push
cd -
git worktree remove /tmp/firebrat-ghpages
```

GitHub Pages rebuilds automatically within a minute or two of a push to `gh-pages`.

## Design notes

- Typefaces are deliberate: **Lexend** (headings) was designed by reading-proficiency researchers to improve reading speed; **Atkinson Hyperlegible** (body) was designed by the Braille Institute for low-vision readers. Both exist because of the same accessibility goals this project has.
- Color tokens and dark-mode handling are in `assets/styles.css`'s `:root` block — light palette by default, `prefers-color-scheme: dark` and an explicit `data-theme` toggle (persisted in `localStorage` by `assets/main.js`) both override it.
- No external dependencies beyond Google Fonts (self-hosting fonts would be a nice follow-up if the site ever needs to work fully offline).
