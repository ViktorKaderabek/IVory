"""Which game screen the bot is looking at.

The readers live next door, by screen: `read_detail` (the Pokémon detail screen and the appraisal),
`read_box` (the storage) and `read_dialog` (the dialogs); `pixels` holds the checks that look at
colors instead of text.
"""
from . import config as cfg
from .vision import find_text
from .grid import complete_cells
from .pixels import find_swatches, is_map, multiselect_look
from .read_box import (
    box_header, keyboard_on, main_menu_on, multiselect_on, search_page_on, sort_menu_on, tag_list_on)
from .read_detail import appraisal_on, detail_menu_on, detail_on
from .read_dialog import confirm_dialog, nickname_dialog, transfer_dialog


def classify(fr):
    """The name of the screen on the frame, e.g. "box", "detail", "appraisal", "map" or "unknown".
    The order matters: a dialog is recognized before the screen it covers, because the texts of the
    screen underneath show through."""
    tx = fr.texts
    if transfer_dialog(tx):
        return "transfer_dialog"
    if confirm_dialog(tx):
        return "confirm_dialog"
    if nickname_dialog(tx):
        return "nickname_dialog"    # over the detail screen, whose texts show through
    if find_text(tx, [cfg.L["enter_tag_name"]]):
        return "tag_dialog"
    if tag_list_on(tx):
        return "tag_dialog" if find_swatches(fr.img) else "tag_list"
    if multiselect_on(tx) or multiselect_look(fr.img):
        return "multiselect"
    if appraisal_on(tx):
        return "appraisal"
    if detail_menu_on(tx):
        return "detail_menu"
    if detail_on(tx):
        return "detail"
    if sort_menu_on(tx):
        return "sort_menu"
    if box_header(tx):
        if keyboard_on(tx):
            return "search_page"   # the keyboard is open for the Search field
        if complete_cells(tx):
            return "box"
        if find_text(tx, ["have this tag"]):
            return "box_tags"
        if search_page_on(tx):
            return "search_page"
        return "box_other"
    if main_menu_on(tx):
        return "main_menu"
    if is_map(fr.img):
        return "map"
    return "unknown"
