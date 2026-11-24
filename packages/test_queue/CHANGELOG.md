## 0.2.0

- `test_queue run --max-rss <GB>` (default 4) stops the run when any one
  process the command started uses more memory than that, and names the
  process. It exits 137. A test stuck allocating in a loop no longer takes
  the machine's whole memory.
- `ProcessTable.residentBytes` reads the resident memory of given pids, and
  `TreeRunner.run` takes `maxResidentBytes`.

## 0.1.0

First release.

- `test_queue run <command>` waits for a slot and enough free memory, then
  runs the command, and kills everything it started when it ends.
- `test_queue status` lists the slots, who holds them, the free memory, and
  stray test processes.
- `test_queue reap` kills test processes left behind by runs that are gone.
