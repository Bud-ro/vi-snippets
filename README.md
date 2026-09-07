# vi-snippets

A collection of permissively licensed LabVIEW VI snippets from across the web,
with attribution.

A VI snippet is a PNG that carries a whole LabVIEW VI in a `niVI` chunk; drag
it onto a block diagram and the code appears. Every file here is byte-identical
to the image published on its source page, so it hashes the same as the
original. `manifest.json` records, per file, the page it was published on and
the image URL (and the uploader where the license asks for attribution);
`LICENSES.md` states the basis on which each source is redistributed. Only
sources with an explicit license or an explicit reuse grant are included.

| directory | files | source | basis |
|---|---|---|---|
| `ni-kb` | 351 | NI Knowledge Base articles | NI's note on the figures that the image "includes LabVIEW code that you can reuse in your project" |
| `labviewwiki` | 63 | LabVIEW Wiki | CC BY 3.0 |
| `stackoverflow` | 259 | Stack Overflow answers and questions | CC BY-SA 2.5/3.0/4.0, author and post recorded |
| `developpez` | 33 | Developpez.net LabVIEW forum and blogs | code pages state the sources are free of rights |
| `hampel-soft` | 21 | Hampel Software Engineering knowledge base | CC BY-SA 4.0 |
| `erdos-miller` | 17 | Erdos Miller blog (assets in the MIT-licensed `erdosmiller/blog`) | MIT |
| `frc-docs` | 2 | FIRST Robotics Competition documentation (WPI) | CC BY 4.0 |
| `wikimedia-commons` | 1 | Wikimedia Commons | CC BY-SA 4.0 |

`INTERESTING.txt` points readers at the 100 snippets that together cover the
widest range of LabVIEW features (unusual structures and object classes,
embedded pictures, styled text, rare data types, old and new versions), ranked
by feature rarity with a diversity penalty; the reasons name what each one
demonstrates.

`held.json` lists snippet images that were found and verified but are not
included because their source states no reuse license or forbids copying
(NI knowledge-base articles without the reuse note, NI forum attachments, and
several company and university pages). Each entry keeps the page and image
URL so the material can be revisited with permission.

This collection is the sample corpus for [labwright](https://github.com/Bud-ro/labwright);
`dart run packages/labwright_rsrc_parse/tool/fetch_snippets.dart` there fetches
it at a pinned commit.
