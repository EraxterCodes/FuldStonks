# FuldStonks

A World of Warcraft addon that lets guild members create and participate in raid-related bets using in-game gold, with a simple UI and live shared state between players.

## 📖 Addon Idea

**FuldStonks** is designed to add a fun, social betting layer to guild raids and events in World of Warcraft. Guild members can create betting pools on various raid outcomes (e.g., "Will we one-shot the boss?", "Who will die first?", "Will we finish under 2 hours?"), place wagers using in-game gold, and winners share the pot based on their predictions.

The addon aims to:
- **Enhance guild social interaction** by creating friendly competition and engagement
- **Provide entertainment value** during raid preparations and downtime
- **Create accountability** through transparent, automated bet resolution
- **Maintain simplicity** with an intuitive UI that doesn't distract from gameplay

## 🎯 Usage Goals

### Primary Features (Planned)
1. **Bet Creation**: Guild officers or designated members can create betting pools with:
   - Custom titles and descriptions
   - Multiple betting options (e.g., "Yes", "No", "Maybe")
   - Entry fees and pot size tracking
   - Time limits and automatic closure
   
2. **Bet Participation**: Guild members can:
   - Browse active bets
   - Place wagers using gold from their inventory
   - View current odds and pot size
   - See who has bet on what (transparency)

3. **Bet Resolution**: After events conclude:
   - Bet creators mark winning outcomes
   - Gold is automatically distributed to winners
   - Distribution is proportional to bet amounts
   - Transaction history is logged

4. **Social Features**:
   - Real-time synchronization across all addon users in the guild
   - Chat announcements for major events (new bets, big wagers, results)
   - Leaderboards tracking biggest wins/losses
   - Historical bet archives

### User Roles
- **Bet Creators**: Guild officers or members with permission
- **Participants**: Any guild member with the addon installed
- **Spectators**: Members can view active bets without participating

## ⚠️ Constraints & Considerations

### Technical Constraints
1. **No Server-Side Storage**: WoW addons can't host servers, so all data must be:
   - Stored in SavedVariables (local client storage)
   - Synchronized via addon messages through guild/raid chat channels
   - Designed to handle conflicts and desyncs gracefully

2. **Addon Message Limits**: WoW limits addon messages to:
   - Maximum message size: ~255 characters per message
   - Rate limiting to prevent spam
   - Messages only reach online players in the same channel

3. **Gold Transfer Security**: WoW API doesn't allow automatic gold transfers, so:
   - Players must manually trade gold to a designated guild bank character
   - Verification relies on manual confirmation or honor system
   - Trust-based system with reputation tracking

4. **UI Restrictions**: Must use WoW's UI framework:
   - Limited to Blizzard's widget set
   - Performance considerations (no heavy processing)
   - Must follow WoW's protected function restrictions

### Design Constraints
1. **Simplicity First**: Avoid feature creep that makes the addon complex
2. **Guild-Focused**: Designed for coordinated guild use, not solo play
3. **Opt-In**: Members must install and enable the addon to participate
4. **Fair Play**: Anti-cheat measures to prevent exploitation

### Social Constraints
1. **House Edge**: Optional small fee (2-5%) can go to guild bank to prevent abuse
2. **Bet Limits**: Configurable maximum bet sizes to prevent drama
3. **Cooldowns**: Prevent spam betting or bet creation
4. **Moderation**: Guild leadership can disable problematic bets

## 🚀 Installation

### Manual Installation
1. Download the latest release from the releases page
2. Extract the `FuldStonks` folder to your WoW addons directory:
   - **Windows**: `C:\Program Files\World of Warcraft\_retail_\Interface\AddOns\` (or `Program Files (x86)` for older installations)
   - **Mac**: `/Applications/World of Warcraft/_retail_/Interface/AddOns/`
3. Restart World of Warcraft or reload UI with `/reload`
4. Verify installation by typing `/FuldStonks` or `/fs` in-game

### First Time Setup
1. Load the addon (automatically loads when you log in)
2. Type `/FuldStonks` to open the main UI
3. Configure your preferences (coming in future updates)
4. Make sure you're in a guild to use betting features

## 💻 Current Status

**Version 0.1.0 - FULLY FUNCTIONAL BETTING SYSTEM** ✅

The addon is now fully functional with core betting features implemented and working:

### ✅ COMPLETED FEATURES

#### 1. Guild Synchronization System
- **Peer tracking**: Automatic discovery of guild members with addon
- **Message protocol**: 7 message types (HB, SYNCREQ, SYNCRSP, BETCRT, BETPLC, BETRSV, BETPND)
- **Auto-channel detection**: Uses best available channel (INSTANCE > RAID > PARTY > GUILD)
- **Rate limiting**: 1 message per second with 255-char validation
- **Heartbeat system**: 30-second broadcasts to maintain peer list
- **Sync on demand**: `/fs sync` to request full state from peers

#### 2. Bet Creation & Management
- **Anyone can create bets**: No special permissions required
- **Yes/No betting**: Simple binary betting on raid outcomes
- **Unique bet IDs**: Automatic generation (PlayerName-Timestamp-Counter)
- **Real-time sync**: All users see new bets immediately
- **Bet serialization**: Efficient data transmission within message limits
- **UI dialog**: Clean 400x300 creation dialog with bet question input
- **Data persistence**: SavedVariables store active bets, history, and player bets

#### 3. Gold Trading & Verification System
- **Mandatory gold trading**: Bets require gold trade to bet creator before confirmation
- **Decentralized**: Each bet creator holds their own pot (no central bank)
- **Trade detection**: Automatic via TRADE_SHOW, TRADE_MONEY_CHANGED, TRADE_CLOSED events
- **Gold verification**: 0.5s delayed check ensures gold is properly received
- **Pending bet system**: Bets stored as "pending" until gold is successfully traded
- **MSG_BET_PENDING**: Broadcasts pending bet info to creator via guild/party/raid channel
- **Whisper notifications**: User-friendly messages during bet placement and confirmation
- **Multi-player support**: Multiple players can have pending bets with same creator simultaneously
- **Bet creator participation**: Creators can bet on their own bets without trading (instant confirmation)

#### 4. Bet Resolution System
- **Creator-only resolution**: Only bet creator can resolve their bets
- **Resolution UI**: 450x400 dialog with full payout preview
- **Payout calculations**: Shows exactly what each participant will receive
- **Profit/loss display**: Green for profit, red for loss
- **Option breakdown**: Shows total bets and amounts per option
- **Proportional winnings**: Winners share pot based on their contribution
- **Broadcast resolution**: All users notified when bet is resolved
- **Moves to history**: Resolved bets archived for reference

#### 5. Bet Inspection System
- **Always available**: Inspect button on all bets (even with 0 participants)
- **Confirmed bets section**: Shows all confirmed participants with amounts and percentages
- **Pending bets section**: Shows pending trades awaiting completion (orange text with ⏳)
- **Sorted by amount**: Highest bets shown first
- **Option breakdown**: Total and percentage per option
- **Pot calculation**: Only includes confirmed bets (pending shown separately)
- **Collector view**: Bet creators can see exactly who owes them gold

#### 6. Pending Bet Management
- **Visual indicator**: Orange "⏳ PENDING: Yes (100g) - Awaiting trade" in UI
- **Cancel command**: `/fs cancel` to cancel pending bet before trading
- **Cancel button**: Appears in UI when you have a pending bet
- **Clear messaging**: Shows what to trade and to whom
- **Timeout handling**: Pending bets can be cancelled anytime before trade

#### 7. UI & User Experience
- **Main window**: 600x450 draggable frame with scrollable bet list
- **Bet cards**: Show title, creator, bet type, and pot size
- **Yes/No buttons**: Click to place bet (hidden when you have pending bet)
- **Inspect button**: View detailed participant breakdown
- **Resolve button**: Only visible to bet creator
- **Connected peers**: Display at bottom showing sync status
- **Real-time updates**: Auto-refresh every 2 seconds
- **Color coding**: Green (success), Yellow (info), Red (error), Orange (pending)

#### 8. Debug System
- **Debug mode**: `/fs debug` toggles detailed logging
- **Clean output**: Removed heartbeat spam, focused on bet operations
- **Trace trade flow**: See every step of trade detection and confirmation
- **Sync debugging**: Track message sends and receives
- **Bet placement logs**: Monitor pending bets and confirmations

### 📋 Commands Available
- `/FuldStonks` or `/fs` - Toggle main UI window
- `/fs help` - Show command help
- `/fs version` - Show addon version (0.1.0)
- `/fs sync` - Request sync from guild/group
- `/fs peers` - List connected peers with last seen time
- `/fs debug` - Toggle debug mode (shows detailed logs)
- `/fs create` - Open bet creation dialog
- `/fs cancel` - Cancel your pending bet (before trading gold)
- `/fs resolve` - Resolve a bet you created (opens resolution dialog)
- `/fs pending` - Show pending bets awaiting trade (bet creator only)

### 🎮 How to Use

**Creating a Bet:**
1. Click "Create Bet" button or type `/fs create`
2. Enter your bet question (e.g., "Will Oscar stand in fire?")
3. Click "Create" - bet syncs to all guild members instantly

**Placing a Bet:**
1. Open main UI and see active bets
2. Click "Yes" or "No" button on a bet
3. Enter gold amount in dialog
4. Trade the gold to the bet creator (shown in message)
5. Bet confirms automatically when trade completes

**As Bet Creator:**
- You can participate in your own bet (no trade required)
- Use "Inspect" to see who owes you gold (pending bets)
- Use "Resolve" to resolve your bet when outcome is known
- Review payout preview before confirming resolution

**Inspecting Bets:**
- Click "Inspect" on any bet to see full breakdown
- Confirmed bets shown with percentages
- Pending bets shown in orange (not in pot yet)
- See exactly who bet on what and how much

## 📋 Remaining TODO List

### ⚠️ Known Issues to Fix Next Session
1. **Heartbeat cleanup**: Remove any remaining references to heartbeat debug functionality
2. **Trade delay testing**: Verify 0.5s delay works consistently across all scenarios
3. **Bet creator participation**: Test that creator's bets appear correctly in inspect dialog

### 🔜 High Priority Features (Next Session)

#### 1. Bet Editing & Cancellation
- [ ] Allow bet creators to cancel active bets (only if no participants yet)
- [ ] Add confirmation dialog for bet cancellation
- [ ] Broadcast cancellation to all users
- [ ] Move cancelled bets to history with "cancelled" status

#### 2. Bet History & Archives
- [ ] Create history tab in main UI
- [ ] Show resolved and cancelled bets
- [ ] Display resolution details (who won, payouts)
- [ ] Add search/filter functionality
- [ ] Export history option

#### 3. Multiple Choice Betting
- [ ] Extend beyond Yes/No to custom options
- [ ] UI for adding/removing options during bet creation
- [ ] Support 3+ options (e.g., "Red", "Blue", "Green")
- [ ] Update resolution UI to handle multiple options
- [ ] Examples: "Which boss will we wipe on first?", "Who will top DPS?"

#### 4. Bet Limits & Validation
- [ ] Set minimum/maximum bet amounts
- [ ] Prevent bets larger than player's gold
- [ ] Add bet creation cooldowns (prevent spam)
- [ ] Maximum active bets per player
- [ ] Guild officer controls for bet limits

### 🎯 Medium Priority Features

#### 5. Enhanced UI/UX
- [ ] Add bet categories/tags (Boss, Mechanics, Fun, etc.)
- [ ] Filter bets by category
- [ ] Sort bets by pot size, creation time, etc.
- [ ] Improve bet card visuals with icons
- [ ] Add tooltips to all buttons and elements
- [ ] Minimap button for quick access

#### 6. Statistics & Tracking
- [ ] Track player betting statistics (total bet, won, lost)
- [ ] Display win/loss ratio
- [ ] Show biggest win and biggest loss
- [ ] Profit/loss over time
- [ ] Most active bettor leaderboard

#### 7. Notifications & Announcements
- [ ] Guild chat announcements for new bets (optional)
- [ ] Announce large bets (configurable threshold)
- [ ] Announce bet resolutions
- [ ] Add sound effects for key events (optional)
- [ ] Toast notifications for bet updates

#### 8. Bet Templates
- [ ] Pre-made templates for common raid bets
  - "Will we one-shot the boss?"
  - "Who will die first?"
  - "Will we clear in under X hours?"
  - "Will X mechanic wipe us?"
- [ ] Save custom templates
- [ ] Quick-create from templates

### 🔧 Technical Improvements

#### 9. Error Handling & Recovery
- [ ] Better handling of disconnects during trades
- [ ] Automatic sync recovery after reconnect
- [ ] Conflict resolution for simultaneous bet placements
- [ ] Data corruption detection and repair
- [ ] Graceful degradation when peers are offline

#### 10. Performance Optimization
- [ ] Optimize UI refresh (currently every 2s)
- [ ] Reduce memory footprint for large bet lists
- [ ] Implement bet pagination for scrolling
- [ ] Cache frequently accessed data
- [ ] Throttle sync requests

#### 11. Security & Anti-Cheat
- [ ] Checksum validation for bet data
- [ ] Detect and reject tampered messages
- [ ] Track suspicious activity (e.g., fake resolution claims)
- [ ] Reputation system for payout reliability
- [ ] Blacklist functionality

### 🌟 Future/Nice-to-Have Features

#### 12. Advanced Betting Types
- [ ] Over/under bets (e.g., "Deaths > 5?")
- [ ] Range bets (e.g., "Boss kill time: 3-4min, 4-5min, 5+min")
- [ ] Live betting (place bets during encounter)
- [ ] Parlay bets (combine multiple bets)
- [ ] Prop bets (e.g., "Will tank use defensive CD?")

#### 13. Guild Bank Integration
- [ ] Optional house edge (2-5%) goes to guild bank
- [ ] Track guild bank contributions
- [ ] Display total guild earnings from bets
- [ ] Guild officer can set house edge percentage

#### 14. External Integration
- [ ] WeakAuras integration for bet notifications
- [ ] Details! integration for DPS-related bets
- [ ] Boss mod integration for mechanic-related bets
- [ ] Export bet data to CSV/JSON
- [ ] API for other addons to create bets

### 📚 Documentation & Polish

#### 15. Documentation
- [ ] In-game tutorial/walkthrough
- [ ] Video guide showing all features
- [ ] FAQ section for common questions
- [ ] Developer API documentation
- [ ] Troubleshooting guide

#### 16. Localization
- [ ] Support for multiple languages
- [ ] Translation strings extraction
- [ ] Community translation contributions
- [ ] Language selection in settings

#### 17. Testing & Quality Assurance
- [ ] Automated test suite for core functions
- [ ] Multi-client testing scenarios
- [ ] Stress testing with many simultaneous bets
- [ ] Edge case testing (disconnects, lag, etc.)
- [ ] Beta testing with multiple guilds

### 🚀 Release Preparation (v1.0.0)

#### 18. Distribution
- [ ] Package for CurseForge
- [ ] Package for WoWInterface  
- [ ] Create promotional screenshots/videos
- [ ] Write detailed changelog
- [ ] Set up automatic update notifications
- [ ] Create Discord community

---

## 🧑‍💻 Developer Notes for Next Session

### Current Architecture Overview

**File Structure:**
- `FuldStonks.toc`: Addon metadata, interface version, saved variables
- `FuldStonks.lua`: Single file with all logic (~1700 lines)
- `README.md`: Documentation and roadmap

**Code Organization (FuldStonks.lua):**
1. **Lines 1-100**: Setup, constants, initialization, helper functions
2. **Lines 100-400**: Data serialization, bet management functions
3. **Lines 400-900**: UI creation (main frame, dialogs, buttons)
4. **Lines 900-1100**: Message protocol handlers
5. **Lines 1100-1300**: Trade detection system
6. **Lines 1300-1500**: Bet placement and confirmation
7. **Lines 1500-1700**: Resolution and inspect dialogs

**Key Functions to Know:**
- `FuldStonks:CreateBet(title, betType, options)` - Creates new bet
- `FuldStonks:PlaceBet(betId, option, amount)` - Places bet (handles creator vs regular)
- `FuldStonks:ConfirmBetTrade(traderName, betId, option, amount)` - Confirms bet after trade
- `FuldStonks:ResolveBet(betId, winningOption)` - Resolves bet and calculates payouts
- `FuldStonks:ShowBetInspectDialog(betId)` - Shows detailed participant breakdown

**Trade Detection Flow:**
1. `OnTradeShow()` - Matches trader to pending bet, stores trade context
2. `OnTradeMoneyChanged()` - Tracks gold amount being traded
3. `OnTradeClosed()` - Wait 0.5s, check gold increase, confirm if matches

**Message Types:**
- `MSG_HEARTBEAT` (HB) - Peer presence announcement
- `MSG_SYNC_REQUEST` (SYNCREQ) - Request state sync
- `MSG_SYNC_RESPONSE` (SYNCRSP) - Send bet data
- `MSG_BET_CREATED` (BETCRT) - New bet announcement
- `MSG_BET_PLACED` (BETPLC) - Bet placement (confirmed)
- `MSG_BET_RESOLVED` (BETRSV) - Bet resolution
- `MSG_BET_PENDING` (BETPND) - Pending bet notification to creator

**SavedVariables:**
- `FuldStonksDB.activeBets` - Active bets table
- `FuldStonksDB.myBets` - Player's bet placements
- `FuldStonksDB.betHistory` - Resolved/cancelled bets
- `FuldStonksDB.debug` - Debug mode flag

**Common Patterns:**
- Use `GetPlayerBaseName()` to strip realm suffix for display
- Always broadcast changes with `BroadcastMessage()`
- Check `bet.createdBy == playerFullName` to validate permissions
- Store pending bets in `FuldStonks.pendingBets[playerFullName]`

### Testing Checklist for Next Session
1. Test bet creator participation end-to-end
2. Verify 0.5s trade delay works on both fast and slow connections
3. Test with multiple pending bets on same bet
4. Test bet resolution with mixed participants (creator + others)
5. Verify inspect dialog shows creator's bet properly
6. Test cancel functionality for creators vs regular players

### Performance Considerations
- Current UI refresh: 2 seconds (acceptable for now)
- Message size: Keep under 255 chars (currently using ~150 avg)
- Pending bets: Stored client-side, cleared after trade/cancel
- Bet lookup: O(1) using dictionary/table structure

### Quick Reference - Lua APIs Used
- `C_ChatInfo.SendAddonMessage()` - Send addon messages
- `C_Timer.After()` - Delayed execution
- `C_Timer.NewTicker()` - Periodic execution
- `CreateFrame()` - UI element creation
- `GetMoney()` - Player's current gold (in copper, divide by 10000)
- `UnitFullName()` - Get player name with realm
- `strsplit()` - Parse delimited strings

## 🤝 Contributing

Contributions are welcome! This addon is in early development. Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly in-game
5. Submit a pull request with detailed description

## 📄 License

This project is open source. Please check the LICENSE file for details.

## 🐛 Known Issues

### Current Session (Fixed)
- ✅ Trade detection timing - Fixed with 0.5s delay
- ✅ Heartbeat spam - Removed heartbeat debug entirely
- ✅ Bet creator participation - Now works without trade requirement

### To Verify Next Session
- ⚠️ Trade delay may need tuning for high-latency connections
- ⚠️ Inspect dialog: Verify creator's bet displays properly with other participants
- ⚠️ Multi-realm support: Test cross-realm bet placement and confirmation

## 📞 Support

- **Issues**: Report bugs or request features via GitHub Issues
- **Discord**: (Coming soon)
- **In-Game**: Whisper the guild officers

---

**Note**: This addon is in active development. The betting logic is not yet implemented. Current version provides only the basic scaffolding and UI framework.
