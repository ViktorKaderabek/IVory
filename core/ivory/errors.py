"""Exceptions the bot uses to steer a run (recoverable step errors and fatal stops)."""


class StepError(Exception):
    """A step failed; the bot returns to the storage and continues."""


class Danger(StepError):
    """The tap could hit a dangerous button, so it was not made."""


class LostPosition(StepError):
    """Lost the place in the storage while scrolling; the bot goes through it again from the top."""


class TagCreated(StepError):
    """A tag was just created; the tag picker is closed without saving and opened again (not an error)."""


class NeedTop(StepError):
    """The next step needs the list from the start; the storage is closed and opened again (not an error)."""


class NotInSearch(StepError):
    """The Pokémon is not in the results of the search by CP (the CP was probably misread)."""


class NotOnScreen(StepError):
    """An entry from the list is not on screen although its neighbors say it should be (a cell duplicated
    by scrolling, or it is past the end of the list); it is skipped without going back to the start."""


class NameRefused(StepError):
    """The game refused the new nickname ("This name contains inappropriate text"); the dialog was closed
    with CANCEL, the Pokémon keeps its name and is skipped (the same name would be refused again)."""


class NoNavigation(StepError):
    """The appraisal can't move on to the next Pokémon; fast mode won't work, so the slow mode is used."""


class Fatal(Exception):
    """The run can't continue (a tag can't be created, the search can't be entered, the connection...).

    `help` names the setup step the cause points back to, when it is one: "uiauto", "trust", "devmode",
    "pair" or "signin".
    """

    def __init__(self, message="", help=None):
        super().__init__(message)
        self.help = help


class NotAuthorized(Exception):
    """The iPhone didn't allow control (UI Automation turned off, or WebDriverAgent stuck)."""
