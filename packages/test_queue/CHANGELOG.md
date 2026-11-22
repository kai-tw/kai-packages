## 0.1.0

First release.

- `test_queue run <command>` waits for a slot and enough free memory, then
  runs the command, and kills everything it started when it ends.
- `test_queue status` lists the slots, who holds them, the free memory, and
  stray test processes.
- `test_queue reap` kills test processes left behind by runs that are gone.
