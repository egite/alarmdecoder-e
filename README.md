# alarmdecoder-e

Patches and an update script for an [AlarmDecoder](https://www.alarmdecoder.com/) Pi running
Raspbian 10 (buster), with the webapp on Python 2.7. They change the Nu Tech
[library](https://github.com/nutechsoftware/alarmdecoder) and
[webapp](https://github.com/nutechsoftware/alarmdecoder-webapp) as follows:

| Component | Version | Changes |
|-----------|---------|---------|
| Library | `1.13.14-E` | Zone expiry scales with the number of faulted zones (`max(30s, zones × 5s)`). On panels with many zones open, the keypad takes longer than the stock 30 seconds to cycle back to each zone, so the library kept marking zones restored and then faulted again. |
| Webapp | `0.8.6-E` (shown in the page footer) | Each email notification gets a throttle: at most X emails per Y minutes. Alarm, panic and fire emails are always sent, and the next email that goes out says how many were held back. Also fixes the Zone Tracker Notification Delay option, which never worked. |

The source changes are on the `e-build` branch of each fork:
[egite/alarmdecoder](https://github.com/egite/alarmdecoder/compare/master...e-build) and
[egite/alarmdecoder-webapp](https://github.com/egite/alarmdecoder-webapp/compare/master...e-build).

## Install

On the Pi, as the `pi` user:

```bash
git clone https://github.com/egite/alarmdecoder-e.git ~/alarmdecoder-e
```

```bash
~/alarmdecoder-e/update-pi.sh
```

Then open an email notification in the webapp. Two fields set the throttle: **Throttle: Maximum
Emails** and **Throttle: Period (minutes)**. Leaving either at 0 means no limit.

## Update

```bash
~/alarmdecoder-e/update-pi.sh
```

The script:

1. Pulls the latest version of this repo.
2. Patches the webapp checkout in `/opt/alarmdecoder-webapp` and commits the change there, so the
   webapp's own **Update** button (a `git merge`) keeps working.
3. Patches the installed library (wherever `python` imports `alarmdecoder` from, normally
   `/usr/local/lib/python2.7/dist-packages`).
4. Restarts `gunicorn` if anything changed, and checks that it came back up.

It works out what is already installed. An older version of a patch is removed before the new
one goes on. Running it again when nothing changed does nothing. If a patch doesn't apply
cleanly, it stops and puts back what it removed, so the Pi is never left half patched.

To see what it would do without changing anything:

```bash
~/alarmdecoder-e/update-pi.sh --check
```

Run it as `pi`, not with `sudo`; it calls `sudo` itself where it needs to. The webapp checkout
must have no uncommitted changes.

### After upgrading the library with pip

A `pip install --upgrade alarmdecoder` replaces the patched files. Run `update-pi.sh` again
afterwards. Avoid upgrading on buster anyway: recent library releases need `setuptools_scm` at
install time, which is unreliable on Python 2.7.

## Undo

In `/opt/alarmdecoder-webapp`, `git log --oneline` lists the commits named "AlarmDecoder -E
patches". Revert each one, newest first:

```bash
cd /opt/alarmdecoder-webapp && git revert --no-edit <commit>
```

```bash
sudo patch -R -p1 -d /usr/local/lib/python2.7/dist-packages -i ~/alarmdecoder-e/patches/library.patch
```

```bash
sudo systemctl restart gunicorn
```

## Contents

- `update-pi.sh`: the update script.
- `patches/library.patch`, `patches/webapp.patch`: everything that differs from upstream `master`,
  generated from the `e-build` branches.
- `patches/legacy/`: an earlier version of the patches. The script recognises them and replaces them.

## License

MIT, the same as the upstream projects. See [LICENSE](LICENSE).
