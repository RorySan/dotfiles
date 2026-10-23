# actions-runner

The self-hosted GitHub Actions runners on the desktop, and a watchdog that restarts one
when it hangs.

A personal account registers a runner to one repo, so each repo with CI here has its own
runner folder, `~/actions-runner*`, and its own user unit:

| Unit | Folder | Repo |
| --- | --- | --- |
| `actions-runner.service` | `~/actions-runner` | RorySan/autogasto |
| `actions-runner-legacy.service` | `~/actions-runner-legacy` | RorySan/autogasto-legacy |

## The watchdog

After a network drop, a runner's listener can hang: GitHub still shows it online and
idle, it never takes the queued job, and since the process never exits, `Restart=always`
never fires. `runner-watchdog` finds that and restarts the runner's unit.

Every 5 minutes (`runner-watchdog.timer`) it finds the runners itself: each
`~/actions-runner*` folder with a `.runner` file, which names the runner and its repo,
and the user unit whose `WorkingDirectory` is that folder. A runner is restarted when,
on two checks in a row, the same job has been queued over 5 minutes, the runner's labels
cover the job's, and no `Runner.Worker` runs in its folder; at most once per 15 minutes.
GitHub unreachable means nothing is done. It logs only when a job is queued.

`gh` must be signed in with its token in `~/.config/gh/hosts.yml`, and the user must
linger (`loginctl enable-linger`), as the runners already need.

### Install

    ln -s ~/repos/dotfiles/actions-runner/runner-watchdog ~/.local/bin/runner-watchdog
    systemctl --user link ~/repos/dotfiles/actions-runner/runner-watchdog.service \
      ~/repos/dotfiles/actions-runner/runner-watchdog.timer
    systemctl --user enable --now runner-watchdog.timer

### Check it

    DRY_RUN=1 runner-watchdog                  # says what it would do, restarts nothing
    journalctl --user -u runner-watchdog       # what each check did
    systemctl --user list-timers runner-watchdog.timer

`GRACE` (300), `COOLDOWN` (900) and `RUNNERS` (`~/actions-runner*`) can be set in the
environment.

## A runner for a new repo

1. On GitHub, the repo's *Settings › Actions › Runners › New self-hosted runner*: download
   it into `~/actions-runner-<repo>` and run its `./config.sh --url … --token …`.
2. Copy `actions-runner.service` to `actions-runner-<repo>.service` here, with its
   `Description`, `WorkingDirectory` and `ExecStart` pointing at the new folder, then
   `systemctl --user link` it and `systemctl --user enable --now` it.

The watchdog covers it from its next check. Retiring a runner: `systemctl --user disable
--now` its unit, `./config.sh remove --token …` in its folder, and delete the folder.
