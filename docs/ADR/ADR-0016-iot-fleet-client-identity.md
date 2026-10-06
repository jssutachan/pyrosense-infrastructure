# ADR-0016: One fleet-client identity and one IoT policy

- **Status:** Proposed
- **Date:** 2026-09-24
- **Module:** `modules/iot`

## Context

PyroSense-Simulator (`publishers/mqtt.py`) opens **one** MQTT connection
with **one** client ID and **one** certificate. It publishes to
`{base}/{env}/telemetry/{device_id}` on behalf of every device of every
gateway. That makes it neither a device nor a gateway: it is a **fleet
client**.

The AI draft of this module shipped only a per-device policy: connect as
`${iot:Connection.Thing.ThingName}` and publish only to your own topic.
Under that policy the simulator could publish only for a device whose ID
equals its client ID. Every other publish, effectively all of them, would
be denied.

The target hardware model matters too. Wildfire sensor networks in
production use low-power sensors on a LoRa/mesh radio that reach the cloud
through gateways. Dryad Networks' Silvanet (sensors → mesh gateways →
border gateways) is the reference we use. In that model the sensor never
terminates TLS to IoT Core and never holds an X.509 credential. The
gateway does.

## Decision

1. One Thing (`<name_prefix>-fleet-client`), one certificate (ADR-0017)
   and one IoT policy.
2. The policy allows:
   - `iot:Connect` on `client/${iot:Connection.Thing.ThingName}` when
     `iot:Connection.Thing.IsAttached` is true.
   - `iot:Publish` on `topic/{base}/{env}/telemetry/PYRO-T?-????`, with the
     same condition.
3. No per-device policy is created. It is not "deferred debt": nothing in
   the system would hold the identity it protects.

## Rationale

- **Least privilege that the publisher can actually use.** The grant is
  narrowed along every axis that does not break the fleet client:
  - one client ID, bound to a registered Thing and an exclusively attached
    certificate;
  - one environment;
  - one topic family;
  - one device-ID shape;
  - no subscribe, receive or retain.
- **Loud failures instead of silent loss.** `?` wildcards mirror
  `DEVICE_ID_PATTERN`. A publish to a deeper or malformed topic, or to
  another environment (for example the simulator's `env` default `dev`),
  is denied and counted in `PublishIn.AuthError`. With `*` it would be
  accepted and never matched by the rule filter.
- **Falsifiable claim.** A per-device policy adds security only if each
  device holds its own credential. If the reference hardware gains a
  sensor class that connects to IoT Core directly (for example cellular
  sensors with their own certificates), this ADR is wrong for that class.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Per-device policy only (AI draft) | Denies the simulator's traffic; models an identity no sensor holds. |
| Per-device + fleet policies coexisting | The per-device policy would be untested dead code in every cycle. A reviewer would read it as a working control. |
| One connection per device in the simulator | ~500 certificates and connections for a demo; the hardware model does not have it either. |
| Real gateway policy now: topic `{base}/{env}/telemetry/{gateway_id}/{device_id}`, publish limited to `.../telemetry/${iot:Connection.Thing.ThingName}/*`, Thing name = gateway ID | This is the right production shape: a compromised gateway can spoof only its own subtree. It changes the topic contract in both repositories and the simulator's connection model (one connection per gateway). Recorded as the trigger target below. |
| Publish to `topic/{base}/{env}/telemetry/*` | Broader than the rule filter (`+`); accepted-but-unrouted publishes become silent losses. |

## Consequences

- **Accepted risk:** the holder of the fleet certificate can publish as
  any `device_id` of its environment. The consumer's contract validation
  (ADR-0006) checks shape, not identity, so this spoofing is detected
  nowhere today.
- The policy is coupled to the payload contract's device-ID format.
- The simulator must use the Thing name as its client ID (`simulator_env`
  output).

## Revision trigger

Any of:

- more than one publishing process per environment;
- real gateway hardware;
- a sensor class that holds its own credential;
- payload contract v2 changing `DEVICE_ID_PATTERN`.

The first two move to the gateway policy described above. The third adds
a per-device policy for that class.
