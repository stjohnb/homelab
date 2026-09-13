(() => {
  const host = window.location.hostname;
  if (host !== "ext.bstjohn.net" && !host.endsWith(".ext.bstjohn.net")) return;
  const rewrite = (url) =>
    typeof url === "string" ? url.replace(/\.home\.bstjohn\.net/g, ".ext.bstjohn.net") : url;
  const rewriteAnchors = () => {
    document.querySelectorAll("a[href]").forEach((a) => {
      const href = a.getAttribute("href");
      const next = rewrite(href);
      if (next !== href) a.setAttribute("href", next);
    });
  };
  rewriteAnchors();
  new MutationObserver(rewriteAnchors).observe(document.body, { childList: true, subtree: true });
})();
