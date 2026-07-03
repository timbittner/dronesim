# Quests & Scenarios

Simple by nature of the drone: "go here", "avoid X", "drop payload",
"stay/observe somewhere". Depends on target/goal marking
([immersion-and-features.md](immersion-and-features.md)).

- **No-fly zones / geofencing** — "avoid X" quests, ties into the jammer
  danger-zone idea and target/goal marking. P5 shipped the `JammingNode`
  primitive (`scripts/mission/jamming_node.gd`) which doubles as a no-fly-zone
  building block.
- **Payload-drop target type** — deferred out of P5 to P6. P5's
  `MissionTarget` (`scripts/mission/mission_target.gd`) has an enum `type`
  (OBSERVE / CRASH) explicitly left extensible for a DELIVER/drop type — the
  drone releases a payload within `radius` to clear it. Pairs with the payload
  physics item in [immersion-and-features.md](immersion-and-features.md).

Later, once terrain/maps are further along: a mission-planning interface
and scenario save/load. Different interface concern from the simple
objective types above — split out if it gets scoped.
