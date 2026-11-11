# Security policy

Elenath is an offline app. It has no network access (the App Sandbox blocks it), no accounts and no servers.
Everything it stores lives in the folder you choose, plus a search index and safety copies in its own container.
Security issues are still possible, for example:

- writing, moving or deleting anything outside your Elenath folder
- losing or corrupting a note, `library.json` or `space.json`, or recovering the wrong data
- following a symbolic link out of the folder
- content from a sealed space showing up outside it (in search, links, suggestions or anything the assistant is
  shown)
- text in a note or an imported file being treated as an instruction by the assistant
- a crafted note, folder name or dropped file that crashes Elenath or makes it misbehave

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub instead:

1. Go to the [Security tab](https://github.com/Visaug36/Elenath/security) of this repository.
2. Click **Report a vulnerability** and describe the problem, with steps to reproduce if you can.

You'll get a reply within a week. Once a fix is ready, it ships in a release and the advisory is published,
crediting you unless you'd rather stay anonymous.

## Supported versions

Only the latest release gets security fixes.
