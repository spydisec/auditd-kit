# Local overlay rules

Put your own audit rules in this directory. Name each file `50-*.rules`, for example
`50-site.rules`.

Overlay rules must not hold control lines. That means no `-D`, `-b`, `-f`, `-e`, `-i`,
`--backlog_wait_time`, or `--loginuid-immutable`. Only the files in `rules/base/` set these, and
the render step removes them from overlay files.
