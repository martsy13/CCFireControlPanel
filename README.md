# CCFireControlPanel

SCADA software for fire alarm, notification, and suppression systems in minecraft on computercraft:tweaked.

# installation and run instructions:
1. download the otmonitor.lua and config.json files to the computer where you plan to run the program.
2. connect the **redstone relay** to the computer using a peripheral cable.
3. connect a 5x8 block or larger monitor to the computer.
4. configure the system (see [system setup](#system-setup)).
5. run otmonitor.lua.

# system setup
1. open the config.json file\
you will see a structure similar to this:
```
{
  "system_title": "Monitor",
  "zones": [
    {
      "id": "ZONE_01",
      "name": "Stage",
      "inputs": ["redstone_relay_1"],
      "col": 1
    },
    {
      "id": "ZONE_02",
      "name": "Auditorium",
      "inputs": ["redstone_relay_2"],
      "col": 1
    }
  ],
  "notification": ["redstone_relay_3"],
  "firefighting": ["redstone_relay_4"]
}
```
