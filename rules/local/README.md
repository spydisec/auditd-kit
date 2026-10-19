# Local overlay rules

The kit doesn't read this directory by itself. Keep your overlay rules in a directory of your
own, and set `akit_extra_rules_dir` (flag `--extra-rules-dir`) to it. Name each file
`50-*.rules`, for example `50-site.rules`.

Overlay rules must not hold control lines. That means no `-D`, `-b`, `-f`, `-e`, `-r`, `-i`,
`--backlog_wait_time`, or `--loginuid-immutable`. Only the files in `rules/base/` set these, and
the render step removes them from overlay files.
