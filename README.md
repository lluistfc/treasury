# Treasury for Ashita v4

A standalone treasure-pool manager inspired by Windower Treasury. It does not depend on XIUI.

Load it with:

```text
/addon load treasury
```

Examples:

```text
/tr pass add Pebble
/tr pass add *crystal
/tr pass add crystals
/tr pass add pool
/tr pass remove Pebble
/tr pass list
/tr lot add 1234
/tr drop add Pebble
/tr delay 2
/tr verbose on
/tr config
/tr inventory
```

`Lot` takes precedence if an item appears in both lists. Rules are stored as item IDs so localized names or resource-name changes do not break existing rules. Item names, numeric IDs, `*` and `?` wildcards, and these groups are accepted: `crystals`, `seals`, `currency`, `geodes`, `avatarites`, `detritus`, and `heroism`.

The `drop` list removes matching items only after they arrive in the player's main inventory. It never passes or lots those items in the treasure pool, so a configured item remains available there when inventory is full.

```text
/tr drop add <item name, id, wildcard, or group>
/tr drop remove <item name, id, wildcard, or group>
/tr drop list
/tr drop clear
```

Dropping is destructive and removes the complete matching stack. The addon validates the live inventory slot again immediately before sending the discard request.

## Windows

Use `/tr config` to open the configuration window. Its Pass, Lot, and Drop tabs show every configured item and allow individual rules to be removed. The **Open Inventory List** button opens the Inventory window.

Use `/tr inventory` to open the Inventory window directly. It lists non-equippable items in the player's main Inventory and provides an **Add** button for items that are not already on the drop list. Equipped and equippable items are omitted. Adding an item saves the rule and schedules all matching main-Inventory stacks for removal, just like `/tr drop add`.

## Original project

This addon is an Ashita v4 port inspired by Ihina's Treasury addon and the
Windower contributors who maintained it. The original Windower source is in
[Windower/Lua](https://github.com/Windower/Lua/tree/live/addons/Treasury).
Its BSD 3-Clause license is retained in `LICENSE-WINDOWER`.
