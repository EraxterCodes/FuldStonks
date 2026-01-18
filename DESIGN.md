# FuldStonks State-Based Synchronization Design

## Overview

FuldStonks v0.2.0 implements a **state-based peer-to-peer synchronization** system for distributed WoW addon communication. This document explains the design decisions, trade-offs, and implementation details.

## Problem Statement

The original v0.1.0 system used **real-time event broadcasting**:
- Each action (bet creation, placement, resolution) sent immediate messages to all peers
- Required all peers to be online when events occurred
- Complex event ordering and replay logic
- Difficult to recover from disconnections
- Race conditions with simultaneous events
- Network delays caused inconsistent views

## Solution: State-Based Synchronization

### Core Concept

Instead of broadcasting individual events, each peer broadcasts their **complete addon state** periodically (every 5 seconds). Peers merge received states with their local state using **conflict resolution rules**.

### Key Benefits

1. **Eventually Consistent**: All peers converge to the same state over time
2. **Offline Tolerant**: Peers automatically catch up when they reconnect
3. **Self-Healing**: State continuously re-broadcast, correcting any inconsistencies
4. **Simpler Logic**: No need to replay event sequences or track event ordering
5. **Easier Debugging**: Full state visible at any time

## Architecture

### State Representation

```lua
-- Global state
FuldStonksDB = {
    stateVersion = 42,        -- Lamport clock (global)
    syncNonce = 7,            -- Sync session counter
    activeBets = {
        ["Player1-123-1"] = {
            id = "Player1-123-1",
            title = "Will we wipe?",
            stateVersion = 42,  -- Bet-specific version
            participants = {
                ["Player2-Realm"] = {
                    option = "Yes",
                    amount = 100,
                    timestamp = 1234567890
                }
            }
        }
    }
}
```

### Lamport Clock Algorithm

**Lamport clocks** provide a logical ordering of events in a distributed system:

```
On local state change:
    stateVersion++

On receiving message with version V:
    stateVersion = max(local, V) + 1
```

This ensures:
- If event A happens before event B locally, then clock(A) < clock(B)
- If event A causally precedes event B (across peers), then clock(A) < clock(B)
- Provides partial ordering of events

### State Broadcast Protocol

Every 5 seconds, each peer broadcasts:

1. **HEADER**: `STATESYNC|HEADER|version|nonce|betCount|participantCount`
2. **BET** messages (one per bet): `STATESYNC|BET|nonce|index|betId|serializedBet`
3. **PARTICIPANT** messages (one per participant): `STATESYNC|PARTICIPANT|nonce|index|betId|serializedParticipant`

**Nonce** tracks sync sessions to prevent mixing data from different broadcasts.

**Chunking** is necessary because WoW limits addon messages to 255 characters.

### Conflict Resolution

When merging states, conflicts are resolved deterministically:

#### Bet-Level Conflicts

```
if receivedBet.id not in localState:
    // New bet, always accept
    localState[betId] = receivedBet

else if receivedBet.stateVersion > localBet.stateVersion:
    // Received bet is newer, use it
    localState[betId] = receivedBet
    
else if receivedBet.stateVersion == localBet.stateVersion:
    // Tie-breaker: lexicographically smaller creator name wins
    if receivedBet.createdBy < localBet.createdBy:
        localState[betId] = receivedBet
```

#### Participant Conflicts

```
if participant not in bet.participants:
    // New participant, add it
    bet.participants[playerName] = participation
    
else if receivedParticipation.timestamp > localParticipation.timestamp:
    // More recent trade confirmation wins
    bet.participants[playerName] = receivedParticipation
```

### Why These Rules?

1. **Higher version wins**: Most recent change should prevail
2. **Lexicographic tie-break**: Deterministic (all peers make same decision)
3. **Timestamp for participants**: Trade confirmations have precise timing
4. **Always accept new data**: Prevents data loss from missed messages

## Edge Cases & Solutions

### Problem: Peer Goes Offline Mid-Bet

**Scenario**: Player A creates bet, goes offline, Players B & C place bets

**Solution**: 
- B & C see the bet from the last state sync
- They place bets normally (trade to A when A returns)
- When A comes back online, they receive B & C's state
- State merges automatically, A sees B & C's participants

### Problem: Simultaneous Bet Creation

**Scenario**: Players A and B create bets at the same time

**Solution**:
- Both bets have different IDs (player-timestamp-counter)
- Both bets appear in both players' states (no conflict)
- All peers eventually see both bets

### Problem: Race Condition on Bet Resolution

**Scenario**: Bet creator resolves bet while someone is placing a bet

**Solution**:
- Resolved bets move to `betHistory`, removed from `activeBets`
- Pending bet placement will fail (bet no longer active)
- Next state sync shows bet as resolved
- Participant gets their gold back (bet creator hasn't received it yet)

### Problem: Network Partition

**Scenario**: Guild splits into two groups that can't communicate

**Solution**:
- Each partition continues operating independently
- When partition heals, states merge via conflict resolution
- Higher state version wins for each bet
- May result in some "lost" bets if both sides modified the same bet
- This is **eventual consistency** - better than total failure

### Problem: Malicious Peer

**Scenario**: Someone tries to broadcast fake state

**Solution** (current limitations):
- No cryptographic verification in v0.2.0
- Trust-based system (guild members only)
- Future improvement: Add checksums or signatures
- Social moderation: Remove malicious users from guild

## Performance Analysis

### Bandwidth

For 10 active bets with 5 participants each:
- Header: ~30 chars
- Bets: 10 × ~100 chars = 1000 chars
- Participants: 50 × ~40 chars = 2000 chars
- **Total: ~3KB per sync**

At 5-second intervals:
- ~36KB/min
- ~2MB/hour
- Acceptable for WoW's network

### CPU

State broadcast:
- Serialize: O(n) where n = number of bets
- Typically < 20 bets, negligible CPU

State merge:
- Compare: O(n) where n = number of bets
- Typically < 50ms even for 100 bets

### Memory

Each bet: ~1KB (including participants)
Pending state updates: ~3KB per peer during sync
Total: ~50KB for typical usage

## Trade-Offs

### Why 5 Seconds?

| Interval | Pros | Cons |
|----------|------|------|
| 1s | Near real-time | High bandwidth, spam risk |
| 3s | Responsive | Still somewhat chatty |
| **5s** | **Good balance** | **Acceptable delay** |
| 10s | Lower bandwidth | Feels unresponsive |
| 30s | Very low bandwidth | Poor UX |

**Decision**: 5 seconds balances responsiveness with efficiency.

### Why Full State Instead of Delta?

**Full State Pros**:
- Simpler implementation
- Self-healing (missing data recovered automatically)
- Easier to debug (complete picture always visible)
- Offline peers catch up easily

**Delta Pros**:
- Lower bandwidth
- Faster transmission

**Decision**: Full state is more robust and easier to reason about. Bandwidth is acceptable for typical usage.

### Why Lamport Clocks Instead of Vector Clocks?

**Lamport Clocks**:
- Simple: Single integer
- Provides partial ordering
- Sufficient for our needs

**Vector Clocks**:
- Complex: Array of integers (one per peer)
- Provides full causal ordering
- Overkill for betting system

**Decision**: Lamport clocks are simpler and adequate. We don't need to detect all concurrent events, just resolve conflicts deterministically.

## Future Improvements

### Short-Term (v0.3.0)

1. **Compression**: Use bit-packing for boolean fields
2. **Delta Optimization**: Send only changed bets when possible
3. **Bloom Filters**: Quick check if peer has same state
4. **Adaptive Interval**: Sync faster when activity is high

### Long-Term (v1.0.0)

1. **Merkle Trees**: Efficient state comparison
2. **Cryptographic Signatures**: Prevent state tampering
3. **Persistent History**: Full audit trail
4. **P2P Discovery**: Dynamic peer discovery without guild requirement

## Testing Strategy

### Unit Tests Needed

1. **Lamport Clock**: Verify increment and update rules
2. **Conflict Resolution**: Test all conflict scenarios
3. **Serialization**: Round-trip encoding/decoding
4. **State Merge**: Complex multi-peer scenarios

### Integration Tests Needed

1. **2-Peer Sync**: Basic state exchange
2. **3-Peer Sync**: Triangle topology
3. **Network Partition**: Split and heal
4. **Offline Recovery**: Disconnect and reconnect
5. **Large State**: 50+ bets with 100+ participants

### Manual Testing Checklist

- [ ] Create bet while peer offline, verify sync when they return
- [ ] Simultaneous bet creation from 3 players
- [ ] Bet resolution while someone is placing bet
- [ ] Network delay simulation (laggy connection)
- [ ] State divergence and recovery
- [ ] Large guild (20+ peers) stress test

## Conclusion

The state-based synchronization system provides:
- ✅ Robust distributed consistency
- ✅ Automatic offline recovery
- ✅ Simple conflict resolution
- ✅ Self-healing architecture
- ✅ Acceptable performance

The trade-offs are well-balanced for a guild betting addon, prioritizing reliability and ease of implementation over absolute real-time performance.

## References

- [Lamport Clocks](https://en.wikipedia.org/wiki/Lamport_timestamp)
- [Eventual Consistency](https://en.wikipedia.org/wiki/Eventual_consistency)
- [Conflict-free Replicated Data Types (CRDTs)](https://crdt.tech/)
- [WoW Addon Message API](https://wowpedia.fandom.com/wiki/API_C_ChatInfo.SendAddonMessage)
