from firebrat.pipeline.compile_llm import _anchor_page_illustration
from firebrat.pipeline.schema import LLMOutput


def script(pages=(0,), ref=None):
    return LLMOutput.model_validate({'sections': [{'title': 'Story', 'source_pages': list(pages),
        'segments': [{'type': 'prose', 'text': 'Four rabbits lived under a tree.', 'ref': ref}]}]})


def test_single_page_illustration_survives_missing_model_reference():
    output = script()
    _anchor_page_illustration(output, [{'page_idx': 0, 'figures': [{'figure_id': 'fig_0001'}]}])
    segment = output.sections[0].segments[0]
    assert segment.ref == 'fig_0001'
    assert segment.type == 'figure_callout'
    assert segment.text == 'Four rabbits lived under a tree.'


def test_alignment_does_not_guess_across_pages_or_replace_explicit_refs():
    pages = [{'page_idx': 0, 'figures': [{'figure_id': 'fig_0001'}]}]
    ambiguous = script((0, 1))
    _anchor_page_illustration(ambiguous, pages)
    assert ambiguous.sections[0].segments[0].ref is None
    explicit = script(ref='formula_0001')
    _anchor_page_illustration(explicit, pages)
    assert explicit.sections[0].segments[0].ref == 'formula_0001'
    multiple = script()
    pages[0]['figures'].append({'figure_id': 'fig_0002'})
    _anchor_page_illustration(multiple, pages)
    assert multiple.sections[0].segments[0].ref is None
