# SPDX-License-Identifier: GPL-3.0-or-later
"""Run commands whose argv may carry a secret, and guard entry points that run them.

`security unlock-keychain -p <password>` and friends put a secret on argv. Python's own
exception text (TimeoutExpired, CalledProcessError, a KeyboardInterrupt chained to either)
prints the full argv, so a hung command plus Ctrl-C would print the password. Every such
call goes through run(); every script that makes one runs its main through guard().

- run() catches BaseException around the child, never chains, and raises CommandError
  whose message names only the tool and its subcommand; output is never included.
- guard() is the last line of defence for the whole process: KeyboardInterrupt and any
  other exception become one sanitized line and an exit status, and the interpreter's
  excepthook is replaced so nothing that slips past still prints a traceback.
"""
from pathlib import Path
import re
import subprocess
import sys


class CommandError(RuntimeError):
    """Safe to print: never contains argv values or tool output."""


class Interrupted(BaseException):
    """A KeyboardInterrupt with its chained exception (and its argv) dropped."""


def label(command):
    """The tool's file name and, when it looks like one, its subcommand. Never a value."""
    parts = [str(part) for part in command]
    name = Path(parts[0]).name if parts else '?'
    if len(parts) > 1 and re.fullmatch(r'[a-z][a-z0-9-]{0,40}', parts[1]):
        name += ' '+parts[1]
    return name


def run(command, *, timeout=None, runner=None, check=True, **kwargs):
    """subprocess.run with captured output; failures are CommandError with no argv."""
    argv = [str(part) for part in command]
    runner = runner or subprocess.run
    try:
        result = runner(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired:
        failure = 'timed out'
    except KeyboardInterrupt:
        failure = None
    except BaseException as error:
        failure = 'could not run ('+type(error).__name__+')'
    else:
        if check and result.returncode:
            raise CommandError(label(argv)+' failed; exit '+str(result.returncode))
        return result
    # Raised outside the except blocks, so nothing is chained, not even implicitly.
    if failure is None:
        raise Interrupted(label(argv))
    raise CommandError(label(argv)+' '+failure)


def _hook(kind, value, traceback):
    sys.stderr.write('Stopped: '+kind.__name__+'\n')


def guard(main, failure='Failed'):
    """Run main() and exit. Prints one sanitized line on any exception; 130 on interrupt."""
    sys.excepthook = _hook
    try:
        main()
    except SystemExit:
        raise
    except (KeyboardInterrupt, Interrupted):
        status, message = 130, 'Interrupted'
    except CommandError as error:
        status, message = 1, failure+': '+str(error)
    except BaseException as error:
        status, message = 1, failure+' ('+type(error).__name__+')'
    else:
        sys.exit(0)
    sys.stderr.write(message+'\n')
    sys.exit(status)
