# Adapter

Your organisation's layer. It is rendered after CORE, so anything here refines or overrides CORE —
except the floor (`core/AGENTS.md` → *Precedence*).

Copy this directory once, to wherever your organisation keeps its rules. It is a seed, not a
dependency: it never updates, and nothing here is overwritten by pulling CORE.

What belongs here:

- rules specific to your organisation, products or clients;
- the evidence — incidents, names, numbers — behind rules you contribute upstream;
- your vocabulary: artifact types, where each one lives, who owns it;
- pointers to your own trackers, knowledge base and tools.

What never belongs here: secrets. Record where a secret lives, never its value.
