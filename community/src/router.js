// Tiny hash router. Handlers receive {params, query} and return
// an Element or a Promise of one.

const routes = [];

function compile(pattern) {
  const names = [];
  const src =
    "^" +
    pattern
      .split("/")
      .map((seg) => {
        if (seg.startsWith(":")) {
          names.push(seg.slice(1));
          return "([^/?#]+)";
        }
        return seg.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      })
      .join("/") +
    "/?$";
  return { re: new RegExp(src), names };
}

/** Register a route, e.g. route("/book/:id", view). */
export function route(pattern, handler) {
  routes.push({ ...compile(pattern), pattern, handler });
  return handler;
}

function parseHash() {
  const raw = location.hash.startsWith("#") ? location.hash.slice(1) : location.hash;
  const [pathPart = "/", queryPart = ""] = raw.split("?");
  return { path: pathPart || "/", query: new URLSearchParams(queryPart) };
}

/** Navigate to a path (leading "#/" added automatically). */
export function navigate(path) {
  const p = path.startsWith("/") ? path : `/${path}`;
  if (`#${p}` === location.hash) {
    window.dispatchEvent(new HashChangeEvent("hashchange"));
  } else {
    location.hash = `#${p}`;
  }
}

async function render(outlet) {
  const { path, query } = parseHash();
  for (const r of routes) {
    const m = r.re.exec(path);
    if (!m) continue;
    const params = Object.fromEntries(
      r.names.map((n, i) => [n, decodeURIComponent(m[i + 1] ?? "")]),
    );
    outlet.replaceChildren();
    const node = await r.handler({ params, query });
    if (node) outlet.append(node);
    return;
  }
  outlet.replaceChildren(document.createTextNode("Page not found."));
}

/** Start listening; renders into outletEl on hashchange. */
export function start(outletEl) {
  window.addEventListener("hashchange", () => render(outletEl).catch(console.error));
  return render(outletEl).catch(console.error);
}
