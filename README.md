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

**Version 0.1.0 - Minimal Scaffolding**

This is the initial scaffolding release with:
- ✅ Basic addon structure (.toc and .lua files)
- ✅ Slash commands: `/FuldStonks` or `/fs`
- ✅ Placeholder UI frame
- ✅ Addon message communication hooks (prepared, not implemented)
- ✅ Event handling framework
- ⏸️ No betting logic yet (coming soon)

### Commands Available Now
- `/FuldStonks` or `/fs` - Toggle the main UI window
- `/FuldStonks help` - Display help information
- `/FuldStonks version` - Show addon version

## 📋 Detailed TODO List

### Phase 1: Core Infrastructure (v0.2.0)
- [ ] **Data Models**
  - [ ] Define bet structure (ID, title, options, pot, participants, status)
  - [ ] Define participant structure (playerName, betOption, amount)
  - [ ] Create serialization/deserialization functions for addon messages
  - [ ] Implement data validation and sanity checks

- [ ] **Saved Variables**
  - [ ] Design SavedVariables schema for FuldStonksDB
  - [ ] Implement save/load functions
  - [ ] Add data migration system for future schema changes
  - [ ] Handle corrupted data gracefully

- [ ] **Addon Communication**
  - [ ] Implement message serialization (compress data for 255 char limit)
  - [ ] Create message type handlers (BET_CREATED, BET_PLACED, BET_RESOLVED, etc.)
  - [ ] Build message queue system to handle rate limits
  - [ ] Implement sync request/response protocol for new members
  - [ ] Add conflict resolution for desync scenarios
  - [ ] Create heartbeat system to track online participants

### Phase 2: Bet Management (v0.3.0)
- [ ] **Bet Creation UI**
  - [ ] Create bet creation dialog with form fields
  - [ ] Add option to specify multiple bet choices
  - [ ] Implement bet validation (title, options, timing)
  - [ ] Add preview before publishing
  - [ ] Broadcast new bet to guild

- [ ] **Bet Participation UI**
  - [ ] Display list of active bets
  - [ ] Show bet details (pot size, participants, odds)
  - [ ] Create bet placement dialog
  - [ ] Add gold amount input with validation
  - [ ] Confirm bet placement and broadcast

- [ ] **Bet Management**
  - [ ] Implement bet state machine (Active, Locked, Resolved, Cancelled)
  - [ ] Add bet expiration timers
  - [ ] Create bet cancellation logic (before any bets placed)
  - [ ] Implement bet locking (prevent new bets after cutoff)

### Phase 3: Resolution & Payouts (v0.4.0)
- [ ] **Bet Resolution**
  - [ ] Create resolution UI for bet creators
  - [ ] Validate resolution permissions
  - [ ] Calculate winner distributions
  - [ ] Apply house edge (if configured)
  - [ ] Broadcast resolution to all participants

- [ ] **Payout System**
  - [ ] Display payout amounts for winners
  - [ ] Generate payout notifications
  - [ ] Create manual payout instructions (gold trading)
  - [ ] Track payout completion status
  - [ ] Handle disputed resolutions

- [ ] **Transaction History**
  - [ ] Log all bet transactions
  - [ ] Create transaction history UI
  - [ ] Add filtering and search
  - [ ] Export transaction logs

### Phase 4: Social Features (v0.5.0)
- [ ] **Chat Integration**
  - [ ] Announce new bets in guild chat
  - [ ] Notify large wagers (configurable threshold)
  - [ ] Announce bet resolutions and winners
  - [ ] Add chat command shortcuts

- [ ] **Statistics & Leaderboards**
  - [ ] Track player statistics (bets placed, won, lost, profit)
  - [ ] Create leaderboard UI (biggest winners, most active, etc.)
  - [ ] Add seasonal resets option
  - [ ] Generate performance graphs

- [ ] **Bet Templates**
  - [ ] Create common bet templates (first death, boss kills, time trials)
  - [ ] Allow saving custom templates
  - [ ] Quick-create from templates

### Phase 5: Polish & Advanced Features (v0.6.0+)
- [ ] **Configuration & Settings**
  - [ ] Build settings panel (using Blizzard settings API)
  - [ ] Add permission system (who can create bets)
  - [ ] Configure house edge percentage
  - [ ] Set bet limits and cooldowns
  - [ ] Enable/disable features

- [ ] **Advanced Betting**
  - [ ] Multi-outcome bets (e.g., "How many deaths?")
  - [ ] Parlay bets (combine multiple bets)
  - [ ] Live betting (during raid)
  - [ ] Bet amendments and cancellations

- [ ] **Quality of Life**
  - [ ] Add tooltips everywhere
  - [ ] Implement keyboard shortcuts
  - [ ] Create mini-mode (compact view)
  - [ ] Add sound effects (optional)
  - [ ] Localization support (multiple languages)

- [ ] **Security & Anti-Cheat**
  - [ ] Implement bet validation checksums
  - [ ] Add reputation system for payout reliability
  - [ ] Create blacklist for abusive players
  - [ ] Log suspicious activities

### Phase 6: Testing & Release (v1.0.0)
- [ ] **Testing**
  - [ ] Create test suite for core functions
  - [ ] Test with multiple clients simultaneously
  - [ ] Stress test message synchronization
  - [ ] Test edge cases and error handling
  - [ ] Beta testing with real guild

- [ ] **Documentation**
  - [ ] Write user guide
  - [ ] Create video tutorials
  - [ ] Document API for extensibility
  - [ ] Write FAQ

- [ ] **Distribution**
  - [ ] Package for CurseForge
  - [ ] Package for WoWInterface
  - [ ] Create changelog
  - [ ] Set up update notifications

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

- None yet! This is the initial scaffolding release.

## 📞 Support

- **Issues**: Report bugs or request features via GitHub Issues
- **Discord**: (Coming soon)
- **In-Game**: Whisper the guild officers

---

**Note**: This addon is in active development. The betting logic is not yet implemented. Current version provides only the basic scaffolding and UI framework.
