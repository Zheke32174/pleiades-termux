# Historical copied scripts

The files in this directory predate the `pleiades-edge` runtime and are retained temporarily for mechanism extraction and provenance review.

They are not installed, started, supervised, or supported by the current Termux bootstrap. Many originated as desktop/server scripts and depended on compatibility functions that pretended unavailable facilities such as systemd, sudo, namespaces, and containers existed.

A script may leave this directory only after it is rewritten to satisfy all of the following:

1. observation-only Android/Termux behavior;
2. typed `pleiades.event/v1` output;
3. no fake privilege or lifecycle commands;
4. explicit permission and data-access documentation;
5. offline tests and failure-visible behavior;
6. no network transmission except through a separately authenticated transport.

Do not add this directory to `PATH` and do not bulk-run its contents.
