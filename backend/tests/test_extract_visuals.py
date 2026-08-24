"""Unit tests for extract.py's marker block-tree traversal — pure logic,
tested against fake block objects rather than real marker output (that
needs torch/marker-pdf, only available in the firebrat-extract env; see
AGENTS.md). This is regression coverage for a real bug found and fixed:
figures/tables reachable via more than one structural path in marker's
tree were being emitted twice, and a naive "first occurrence wins" dedup
guard sometimes kept the uncaptioned occurrence over the captioned one.
"""
from firebrat.pipeline.extract import _block_children, _find_visuals_on_page


class FakeBlockId:
    """Mimics marker's BlockId — needs to be hashable and support equality
    so it works as a dict key the same way the real one does."""
    def __init__(self, key):
        self.key = key

    def __hash__(self):
        return hash(self.key)

    def __eq__(self, other):
        return isinstance(other, FakeBlockId) and self.key == other.key


class FakeBlock:
    def __init__(self, block_type, key, children=None, text=""):
        self.block_type = block_type
        self.id = FakeBlockId(key)
        self.children = children
        self.structure = None
        self._text = text

    def raw_text(self, document):
        return self._text


def _page(children):
    return FakeBlock("Page", "page", children=children)


def test_figure_group_pairs_content_with_caption():
    fig = FakeBlock("Figure", "fig1")
    cap = FakeBlock("Caption", "cap1", text="Figure 2.14 Identity theorem")
    group = FakeBlock("FigureGroup", "group1", children=[fig, cap])
    page = _page([group])

    results = _find_visuals_on_page(page, document=None)

    assert len(results) == 1
    content, caption = results[0]
    assert content is fig
    assert caption is cap


def test_bare_table_with_no_group_has_no_caption_block():
    table = FakeBlock("Table", "tbl1", text="Table 2.1 Axioms")
    page = _page([table])

    results = _find_visuals_on_page(page, document=None)

    assert len(results) == 1
    content, caption = results[0]
    assert content is table
    assert caption is None


def test_duplicate_block_reached_two_ways_is_not_emitted_twice():
    fig = FakeBlock("Figure", "fig1")
    cap = FakeBlock("Caption", "cap1", text="Figure 2.9")
    group = FakeBlock("FigureGroup", "group1", children=[fig, cap])
    # The same Figure block also reachable as a bare top-level sibling —
    # this is the real shape of the bug that was found: marker's tree can
    # genuinely expose one block via two structural paths.
    page = _page([fig, group])

    results = _find_visuals_on_page(page, document=None)

    assert len(results) == 1


def test_duplicate_prefers_the_captioned_occurrence_regardless_of_order():
    fig = FakeBlock("Figure", "fig1")
    cap = FakeBlock("Caption", "cap1", text="Figure 2.14 Identity theorem")
    group = FakeBlock("FigureGroup", "group1", children=[fig, cap])
    # Bare (uncaptioned) occurrence visited BEFORE the captioned group —
    # this ordering is exactly what caused the original bug: a plain
    # "first wins" guard kept this uncaptioned one and discarded the real caption.
    page = _page([fig, group])

    results = _find_visuals_on_page(page, document=None)

    assert len(results) == 1
    content, caption = results[0]
    assert caption is cap


def test_skips_line_and_span_and_table_cell_leaves():
    leaf = FakeBlock("Line", "line1")
    span = FakeBlock("Span", "span1")
    cell = FakeBlock("TableCell", "cell1")
    text_block = FakeBlock("Text", "text1", children=[leaf, span])
    table = FakeBlock("Table", "tbl1", children=[cell], text="content")
    page = _page([text_block, table])

    results = _find_visuals_on_page(page, document=None)

    assert len(results) == 1
    assert results[0][0] is table


def test_block_children_falls_back_to_structure_via_document(monkeypatch):
    child = FakeBlock("Figure", "fig1")

    class FakeDocument:
        def get_block(self, block_id):
            return child if block_id.key == "fig1" else None

    parent = FakeBlock("FigureGroup", "group1")
    parent.children = None
    parent.structure = [FakeBlockId("fig1")]

    resolved = _block_children(parent, FakeDocument())

    assert resolved == [child]
