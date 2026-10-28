# Server-provided category filters

The Flutter document-catalog adapter no longer contains a category ID/name table, a built-in category range, or a list of category-specific language exceptions. No replacement encoding or renamed copy of the old classification is used. Native Swift reference files are unchanged.

## Document catalog behavior

- An unfiltered request omits `categories` and accepts the server's category IDs, including IDs outside the former built-in range. It does not classify a numeric ID as a genre, maturity rating or safe-content guarantee.
- `type:73` uses the caller's numeric server category ID directly. It does not assign a name or meaning to ID 73. Positive filters are sent through the existing `categories` request parameter and checked against returned IDs.
- `-type:73` excludes that returned ID locally. Because the client does not know the complete server category set, it does not invent an inclusive list of every other ID. Filtered-out pages still advance the server cursor; results are collected through the existing bounded pagination loop, without duplicating works. A fully excluded terminal response produces an empty result with `hasMore=false`.
- A returned category object with `id` and `label`/`name`, explicit `category_label`/`category_name`, a textual `type`, or a returned `type` tag can supply the category label. An observed ID/label association is cached only within that source instance. Labels remain server data; the app only normalizes case/spaces for the `type:` search token.
- With a numeric category and no label, metadata retains `category_id` and the searchable tag is `type:<ID>`. When a real label exists, metadata also retains `category_label`; the complete original response remains in `gallery`.

## Compatibility limits

The reference document responses in the existing fixtures provide numeric categories, not an authoritative name registry. This change therefore does **not** claim that every connected server supplies category names or category-language capabilities.

A saved query such as `type:manga` that depended on the removed built-in table is unsupported on a document server until a matching ID/label association has actually been returned while browsing or opening a work. It fails with an explicit category-label error; it does not silently run a broader query to discover names. A numeric category filter also fails explicitly if the returned rows lack category IDs. Indexed catalogs continue to use type strings and type indexes supplied by that server, without the removed document ID/name table.

The stored `allowsLanguageExceptions.manga` preference is retained for data compatibility, but the current document and indexed adapters no longer execute its former fixed-category unions. The UI marks this capability unsupported. Document language terms are forwarded without client-created exception lanes; indexed language searches use the selected language index without merging hardcoded type indexes. This can return fewer results than earlier versions. Server enforcement and the accuracy of server metadata still require independent verification.

## Verification and scope

`test/core/manga_source_test.dart` covers unfamiliar IDs, real ID/label and type fields, rejection of an unprovided legacy name without extra search requests, numeric category filtering, exclusion pagination/order/uniqueness, fully excluded pages, missing IDs and retained legacy language preference with stricter execution. Existing manifest parsing, expired-media refresh, indexed search/ranges and transport validation remain covered.

This change removes actual app-owned classification assumptions. It does not remove the remaining catalog/reader protocol adapters, validate a provider's content policy, certify content safety, or establish Google Play eligibility. Existing Safe Mode protection is not relaxed by category metadata, and users are not advised to disable it to access an unsupported connection.
