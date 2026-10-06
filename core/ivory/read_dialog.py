"""The dialogs the bot has to recognize so it can answer them (and never tap the dangerous button)."""
from . import config as cfg
from .vision import find_text
from .pixels import find_swatches


def transfer_dialog(tx):
    return bool(find_text(tx, ["do you want to transfer", "to the professor", "cannot undo"]))


def confirm_dialog(tx):
    """Some other confirmation dialog (evolve, power up...); always answered with NO/CANCEL."""
    return bool(find_text(tx, ["do you want to", "are you sure"]) and find_text(tx, ["no", "cancel"], exact=True))


def nickname_dialog(tx):
    """The Set Nickname dialog (renaming) is open – with or without the keyboard over the screen."""
    return bool(find_text(tx, [cfg.L["set_nickname"]], region=(0.0, 0.2, 1.0, 0.55)))


def name_refused(tx):
    """The game refused the new nickname ("This name contains inappropriate text.")."""
    return bool(find_text(tx, cfg.L["name_refused"]))


def tag_dialog_on(fr):
    """The new-tag dialog: the "Enter tag name" field, or a row of color swatches."""
    return bool(find_text(fr.texts, [cfg.L["enter_tag_name"]]) or find_swatches(fr.img))
