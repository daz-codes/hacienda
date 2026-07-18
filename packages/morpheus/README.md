# Morpheus

Morpheus is a small HTML-first navigation library. It intercepts eligible
same-origin links, prefetches pages on intent, and uses Idiomorph to replace a
single page target while preserving the surrounding document.

```js
import Morpheus from "@lunula/morpheus";

const navigation = new Morpheus({target: "#morpheus-page"});
navigation.start();
```

The package also starts itself when loaded by a module script carrying the
`data-morpheus` attribute:

```html
<script type="module" src="/assets/morpheus.js" data-morpheus></script>
```

Servers opt a response into morphing with `X-Morpheus-Navigation: morph`.
Requests made by Morpheus carry `X-Morpheus-Navigation: true`; prefetched
requests additionally carry `X-Morpheus-Prefetch: true`.

## Browser contract

- The default target is `#morpheus-page`.
- `data-morpheus="off"` opts a link subtree out of interception.
- `data-morpheus-prefetch="off"` disables prefetching for a link subtree.
- `data-morpheus-permanent` preserves an element across page morphs.
- `data-morpheus-active-prefix` maintains `aria-current` on navigation links.
- Browser events use the `morpheus:` namespace.

Morpheus has no runtime Node requirement. The package includes its vendored
Idiomorph ESM dependency and license so it can be served directly by a Ruby or
other HTML-first application.
