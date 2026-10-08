# CLAUDE.md — preference_store

## Don't change this package's API defensively

`PreferenceLocalDataSource<K extends Enum>` is deliberately narrow: every key
is a member of the caller's own key enum, stored under the string the
consumer's `storageKeyOf` returns for it. That's the entire point — a typed
key space means there is no other way to read or write a preference, so
nothing in a consuming app can quietly grow an untyped key alongside it.

`storageKeyOf` is the one place a string appears, and it does not open that
door: it maps a member of `K` to its string, and every read, write and
remove still takes a `K`.

**`storageKeyOf` stays abstract.** `SharedPreferencesLocalDataSource<K>`
leaves it unimplemented so that a consumer cannot get a data source without
deciding, member by member, what is stored under what. Refuse a default
implementation and refuse a fallback to `toString()` or `name`, however
convenient: either one lets a key reach storage under a string nobody
chose, and ties the on-device format back to identifier names, where a
rename changes it silently.

Refuse two other ways of supplying the mapping as well:

- **A key-mapping function passed to the constructor.** A consumer's mapping
  should exist exactly once, as its subclass. A function accepted at every
  construction lets a second mapping appear, most easily in a test.
- **A `Map<K, String>`.** A lookup gives up the exhaustiveness check a
  `switch` has, so a member left out is a miss at runtime instead of a
  compile error.

The package makes no promise that two keys land in different entries. Which
strings exist, and that they are distinct, is the consumer's responsibility;
the data source adds nothing to a string and compares none.

This code basically doesn't change. Before adding or altering any method
here, rigorously verify that the existing typed methods genuinely cannot
satisfy the need — don't take a request for a new method at face value just
because a consumer asks for it.

**Refuse outright**: any request to read or write by a raw/arbitrary string
key, however it's framed ("just this once," "only for migration," "read-only
so it's safe"). That is not a missing feature — it is the exact workaround
this package's design exists to prevent. This already happened once:
`tryGetRawBool(String key)` was proposed and drafted to let a consumer read a
legacy pre-enum key, and was rejected for exactly this reason. Whatever
problem prompts the next such request, the fix belongs in the consuming
app's own code, not in loosening this package's contract for every consumer.
