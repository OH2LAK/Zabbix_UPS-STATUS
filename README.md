# Zabbix NUT UPS Monitoring Template

A Zabbix 7.0 template for monitoring UPS devices via [Network UPS Tools (NUT)](https://networkupstools.org/), using low-level discovery (LLD) to automatically pick up every UPS registered with `upsc -l`, and a JSON-aggregation approach that keeps all metrics for a given poll cycle on the same timestamp.

Tested against:
- **Eaton 5P 850** (usbhid-ups, MGE HID subdriver)
- **Eaton Powerware 9130** (usbhid-ups, MGE HID subdriver)

Should work with any UPS supported by NUT's `usbhid-ups` driver, though field availability varies by model (see [Known field differences](#known-field-differences-between-ups-models)).

## The problem this solves

The common approach to Zabbix + NUT integration is one `UserParameter` call per metric:

```
UserParameter=upsmon[*],/usr/lib/zabbix/externalscripts/ups_status.sh $1 $2
```

Each item (`input.voltage`, `battery.charge`, `ups.load`, ...) then triggers its own separate execution of `upsc`. This has two downsides:

1. **Timestamp drift.** Since each item is polled independently, values for the same UPS end up with slightly different timestamps. This makes "latest data" tables (e.g. the Item History widget) list metrics one at a time instead of grouping them into a single row per poll.
2. **Load on the UPS/USB link.** Querying `upsc` 8-10 times per polling interval is more overhead than necessary.

This template instead defines **one item** that captures the entire `upsc` output as a JSON blob, and all other metrics as **Dependent items** that extract their value from that single JSON blob via JSONPath preprocessing. Because dependent items inherit the timestamp of their master item, every metric from a given poll shares the exact same timestamp.

## Architecture

```
┌─────────────────────────────────────────────┐
│ Zabbix Agent2 UserParameter                  │
│ upsmon.json[*] → ups_status_json.sh $1       │
│   runs `upsc <ups>` ONCE, outputs JSON        │
└───────────────────┬───────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────┐
│ Master item (Zabbix agent, Text)             │
│ UPS {#UPSNAME} Raw Data                      │
│ key: upsmon.json[{#UPSNAME}]                 │
└───────────────────┬───────────────────────────┘
                     │  (dependent items, same timestamp)
        ┌────────────┼────────────┬─────────────┬── ...
        ▼            ▼            ▼             ▼
   Input Voltage  Output Voltage  Charge   Power Factor
   (JSONPath +    (JSONPath +   (JSONPath   (JavaScript:
    round to 1dp)  round to 1dp)  + round)   direct field or
                                             computed fallback)
```

Low-level discovery (`upsmon[ups.discovery]`) runs `upsc -l` and creates a `{#UPSNAME}` macro instance for every UPS NUT knows about, so adding a new UPS to `ups.conf` is enough — no manual Zabbix configuration needed beyond linking the host.

## Repository contents

```
├── README.md
├── templates/
│   └── template_ups_nut.yaml       # Zabbix 7.0 template export
├── scripts/
│   ├── ups_status.sh               # per-parameter script (LLD discovery + legacy single-value calls)
│   └── ups_status_json.sh          # aggregated JSON script (used by the master item)
└── userparameter/
    └── userparameter_nut.conf      # Zabbix Agent2 UserParameter definitions
```

## Requirements

- NUT 2.8.x with `upsc` / `upsd` configured and working (`upsc <upsname>` must return data locally on the monitored host)
- Zabbix Agent2 7.0+ on the monitored host
- Zabbix Server 7.0+ (template uses the `zabbix_export: version: '7.0'` schema; should import fine into any 7.x)
- Read access for the `zabbix`/`nut` agent user to the NUT driver socket (standard NUT permissions apply)

## Installation

### 1. Install the scripts

Copy both scripts to the external scripts directory on the monitored host (adjust the path if your distro differs):

```bash
sudo cp scripts/ups_status.sh scripts/ups_status_json.sh /usr/lib/zabbix/externalscripts/
sudo chmod +x /usr/lib/zabbix/externalscripts/ups_status.sh /usr/lib/zabbix/externalscripts/ups_status_json.sh
```

### 2. Install the UserParameter definitions

```bash
sudo cp userparameter/userparameter_nut.conf /etc/zabbix/zabbix_agent2.d/
sudo systemctl restart zabbix-agent2
```

### 3. Verify locally before touching Zabbix

```bash
# Confirm NUT itself is healthy
upsc <your-ups-name>

# Confirm the discovery script sees your UPS(es)
/usr/lib/zabbix/externalscripts/ups_status.sh ups.discovery

# Confirm the JSON aggregation script works
/usr/lib/zabbix/externalscripts/ups_status_json.sh <your-ups-name>

# Confirm the Zabbix Agent2 UserParameter resolves correctly
sudo -u zabbix zabbix_agent2 -c /etc/zabbix/zabbix_agent2.conf -t "upsmon.json[<your-ups-name>]"
```

The last command should print `[m|ZBX_SUCCESS]` followed by a single-line JSON object. If it doesn't, fix this before importing the template — the dependent items downstream have nothing to work with otherwise.

### 4. Import the template

`Data collection → Templates → Import → templates/template_ups_nut.yaml`

### 5. Link the template to a host

Link the `UPS-status` template to the Zabbix host that runs the NUT driver and has the agent reachable. Discovery will run on its own schedule and create item instances for every `{#UPSNAME}` found.

## What's included in the template

- **Discovery rule**: `UPS Discovery` (`upsmon[ups.discovery]`)
- **Master item**: raw JSON blob per UPS, `Text` type, short history retention (7d), no trends (nothing to graph on raw text)
- **Dependent items**: Input/Output Voltage (1 decimal), Input Frequency, Battery Charge (%, rounded), Battery Runtime (with `uptime` unit formatting for human-readable display), Battery Voltage, UPS Load (%), UPS Power (VA), UPS Realpower (W), UPS Power Factor (see below), UPS Status (mapped to readable text), UPS Temperature (where supported)
- **Triggers**: low battery, on-battery, overload, bypass, offline, trimming/boosting voltage, high temperature (>28°C, adjust to your environment), plus informational triggers for charging/calibration states
- **Graphs**: Voltage (input+output overlay), Load, Charge, Frequency, Temperature
- **Value map**: numeric UPS status codes mapped to readable strings

### UPS status codes

`ups.status` from NUT is a text field (`OL`, `OB`, `LB`, etc., sometimes combined like `OL CHRG`). The scripts translate it to a numeric code so it works cleanly with Zabbix triggers and value maps:

| Code | Meaning |
|---|---|
| 0 | Unknown state |
| 1 | On line (mains present) |
| 2 | On battery (mains not present) |
| 3 | Low battery |
| 4 | Battery needs to be replaced |
| 5 | Battery charging |
| 6 | Battery discharging (inverter providing load power) |
| 7 | UPS bypass circuit active, no battery protection |
| 8 | UPS runtime calibration (on battery) |
| 9 | UPS offline, not supplying power to the load |
| 10 | UPS overloaded |
| 11 | UPS trimming incoming voltage ("buck") |
| 12 | UPS boosting incoming voltage |
| 13 | On line and battery charging (`OL CHRG`) |

### Power Factor: direct read with computed fallback

Some UPS models (e.g. Eaton 5P) expose `output.powerfactor` directly from NUT. Others (e.g. Eaton Powerware 9130) don't. The Power Factor item handles both cases in one JavaScript preprocessing step:

```javascript
var data = JSON.parse(value);

if (data["output.powerfactor"] !== undefined) {
    return Math.round(parseFloat(data["output.powerfactor"]) * 100) / 100;
}

var power = parseFloat(data["ups.power"]);
var realpower = parseFloat(data["ups.realpower"]);

if (!power || power === 0) {
    return 0;
}

return Math.round((realpower / power) * 100) / 100;
```

If the device reports it, use it (it's a direct measurement, more accurate than a derived value). Otherwise, fall back to `ups.realpower / ups.power`.

## Known field differences between UPS models

NUT's `upsc` output is not identical across UPS models — some fields are vendor/model-specific. This template only includes items for fields that were common across the tested devices, with two exceptions handled explicitly (Power Factor above, and Battery Voltage below).

Fields observed as **model-specific** during testing:

| Field | Eaton 5P | Powerware 9130 |
|---|:---:|:---:|
| `battery.voltage`, `battery.capacity` | ✅ | ❌ |
| `input.current`, `output.current`, `output.powerfactor` | ✅ | partial (`output.current` only) |
| `ups.temperature` | ❌ | ✅ |
| `ups.efficiency` | ✅ | ❌ |

If an item's underlying field doesn't exist on a given UPS model, that item simply goes into "Not Supported" state for that host — it does not break polling for the other items. This is expected behavior, not a bug. If your UPS model doesn't report a field a given item expects, you can safely disable that item prototype for your environment, or extend the JSON script/JavaScript preprocessing with your own fallback logic following the Power Factor example above.

## Customizing the discovery script for your own NUT setup

`ups_status_json.sh` is a thin wrapper: it calls `upsc <upsname>`, reformats the `key: value` output into JSON, and adds a numeric `ups.status.code` field by mapping the textual `ups.status` value. If your `upsc` output includes characters that need escaping differently, or you want to add/remove fields before they hit Zabbix, this is the place to do it.

## Credits / background

The discovery approach (`upsmon[ups.discovery]`) and status code mapping originate from [delin/Zabbix-NUT-Template](https://github.com/delin/Zabbix-NUT-Template). This template extends that base with the JSON-aggregation/dependent-item architecture for timestamp consistency, adds Power Factor with a direct-read/computed-fallback strategy, and adds the `OL CHRG` (13) status code that was missing from the original mapping.

## License

MIT
