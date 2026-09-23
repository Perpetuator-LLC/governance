# Contributing

Thank you for giving back. Every change that lands here reaches every installation on its next update,
including yours. See the README → *Use it, build on it, give back* for why that matters.

## What to send

- **A rule** your agents learned the hard way, stated so a stranger at another organisation could
  apply it.
- **A gate or check**, with a test that shows it refusing a known-bad input and allowing a known-good
  one.
- **An extension:** a new domain, support for another agent harness, a template, a better adapter
  default.
- **A fix** to anything here that misled you, broke, or cost you more than it should have.

Small is welcome. A single sharpened sentence is a real contribution.

## The one test every change passes

**Would this still be useful, and still be safe, to a stranger at another company?**

- **The rule travels; the exhibit stays with you.** Keep the incident, the numbers and the names in
  your own adapter, which may link here. Nothing here links back to you. The full model is
  `core/AGENTS.md` → *Contributing a rule upstream*.
- **Leave out** the names of your people, clients, products and hosts, your internal ticket
  references, and paths from your machines.
- **Sharpen before you add.** Search the domain file for the concept first. If a rule already covers
  it, improve that rule rather than writing a second one beside it.

## Before you open a pull request

Run what CI runs:

    for t in tests/*.test.sh; do bash "$t" || echo "FAIL $t"; done
    python3 bin/heading-pointer-check
    python3 bin/redaction-check --enforce $(git ls-files)

The redaction check matches identifier *shapes* only. It cannot know your organisation's names. To
check those too, pass your own list, kept outside this repository:

    python3 bin/redaction-check --enforce --private-patterns <your-list> $(git ls-files)

## Where to send it

Open a pull request on GitHub, or an issue first if you would like to discuss the idea. The GitHub
repository is a mirror of the primary one. An accepted change is applied to the primary repository
with you as its author, and it reaches GitHub through the mirror. Your pull request is then closed
with a link to that commit rather than merged in place.

If you work with an agent, point it at this file and at `core/AGENTS.md` → *Contributing a rule
upstream*. It can draft the change, and you decide what to send.

## License

Contributions are accepted under the same MIT License as the rest of the repository (`LICENSE`).
