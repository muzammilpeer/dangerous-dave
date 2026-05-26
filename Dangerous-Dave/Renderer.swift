//
//  Renderer.swift
//  Dave1
//

import AppKit
import Metal
import MetalKit
import simd

private let tileSize: Float = 32
private let targetWorldHeight: Float = 480
private let maxBoostFuel: Float = 1.5

struct GameVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>

    init(position: SIMD2<Float>, color: SIMD4<Float>) {
        self.position = SIMD4<Float>(position.x, position.y, 0, 1)
        self.color = color
    }
}

enum InputKey {
    case left
    case right
    case down
    case jump
    case shoot
    case pause
    case settings
}

private struct Rect {
    var x: Float
    var y: Float
    var width: Float
    var height: Float

    var minX: Float { x }
    var maxX: Float { x + width }
    var minY: Float { y }
    var maxY: Float { y + height }
    var centerX: Float { x + width * 0.5 }

    func intersects(_ other: Rect) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }
}

private struct TilePoint: Hashable {
    let x: Int
    let y: Int
}

private enum EnemyKind {
    case walker
    case floater
}

private struct Enemy {
    var rect: Rect
    var direction: Float
    var speed: Float
    var kind: EnemyKind = .walker
    var originY: Float = 0
}

private struct Projectile {
    var rect: Rect
    var velocityX: Float
}

private struct FloatingLabel {
    var text: String
    var position: SIMD2<Float>
    var timeRemaining: Float
}

private struct ScoreEntry: Codable {
    let name: String
    let score: Int
}

private struct LevelDefinition {
    let name: String
    let rows: [String]
}

private struct LevelState {
    var definition: LevelDefinition
    var solidTiles: Set<TilePoint> = []
    var hazardTiles: Set<TilePoint> = []
    var waterTiles: Set<TilePoint> = []
    var coins: Set<TilePoint> = []
    var boostPickups: Set<TilePoint> = []
    var secretBonuses: Set<TilePoint> = []
    var trophy: TilePoint?
    var exit: TilePoint?
    var enemies: [Enemy] = []
    var start: SIMD2<Float> = SIMD2<Float>(64, 96)
    var width: Int = 0
    var height: Int = 0
}

private enum GameMode {
    case title
    case levelCard
    case playing
    case paused
    case settings
    case gameOver
    case finished
}

final class Renderer: NSObject, MTKViewDelegate {

    private enum SaveKey {
        static let playerName = "Dave1.playerName"
        static let highScore = "Dave1.highScore"
        static let scoreEntries = "Dave1.scoreEntries"
        static let soundEnabled = "Dave1.soundEnabled"
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    var statusHandler: ((String) -> Void)?

    private var levels: [LevelDefinition] = Renderer.makeLevels()
    private var levelIndex = 0
    private var level: LevelState
    private var player = Rect(x: 64, y: 96, width: 22, height: 28)
    private var velocity = SIMD2<Float>(0, 0)
    private var onGround = false
    private var wantsLeft = false
    private var wantsRight = false
    private var wantsBoost = false
    private var wantsJump = false
    private var previousJump = false
    private var jumpsRemaining = 2
    private var trophyCollected = false
    private var lives = 3
    private var score = 0
    private var highScore: Int
    private var playerName: String
    private var scoreEntries: [ScoreEntry]
    private var soundEnabled: Bool
    private var gameMode: GameMode = .title
    private var settingsReturnMode: GameMode = .title
    private var modeTimer: Float = 0
    private var animationTime: Float = 0
    private var lastFootstepTime: Float = 0
    private var lastBoostSoundTime: Float = 0
    private var boostFuel: Float = 0
    private var projectileCooldown: Float = 0
    private var projectiles: [Projectile] = []
    private var floatingLabels: [FloatingLabel] = []
    private var facingRight = true
    private var lastFrameTime = CACurrentMediaTime()
    private var cameraX: Float = 0
    private var worldWidth: Float = 800
    private var worldHeight: Float = targetWorldHeight

    @MainActor
    init?(metalKitView: MTKView) {
        guard let device = metalKitView.device,
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.highScore = UserDefaults.standard.integer(forKey: SaveKey.highScore)
        self.playerName = Renderer.savedPlayerName()
        self.scoreEntries = Renderer.loadScoreEntries()
        self.soundEnabled = UserDefaults.standard.object(forKey: SaveKey.soundEnabled) as? Bool ?? true

        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.clearColor = MTLClearColor(red: 0.015, green: 0.012, blue: 0.03, alpha: 1.0)

        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Dave1 Retro Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("Unable to compile render pipeline state: \(error)")
            return nil
        }

        let firstLevel = Renderer.parse(level: levels[0])
        self.level = firstLevel
        super.init()
        loadLevel(0, keepScore: true)
    }

    func setKey(_ key: InputKey, isPressed: Bool) {
        if isPressed {
            switch gameMode {
            case .title:
                if key == .settings {
                    settingsReturnMode = .title
                    gameMode = .settings
                    return
                }
                playSound(named: "Hero")
                startNewGame()
                return
            case .finished:
                return
            case .paused:
                if key == .pause {
                    gameMode = .playing
                }
                return
            case .settings:
                handleSettingsKey(key)
                return
            case .gameOver:
                if key == .shoot || key == .jump {
                    startNewGame()
                }
                return
            case .levelCard:
                playSound(named: "Pop")
                gameMode = .playing
            case .playing:
                break
            }
        }

        if isPressed {
            switch key {
            case .shoot:
                fireProjectile()
                return
            case .pause:
                gameMode = .paused
                return
            case .settings:
                settingsReturnMode = gameMode
                gameMode = .settings
                return
            default:
                break
            }
        }

        switch key {
        case .left:
            wantsLeft = isPressed
        case .right:
            wantsRight = isPressed
        case .down:
            wantsBoost = isPressed
        case .jump:
            wantsJump = isPressed
        case .shoot, .pause, .settings:
            break
        }
    }

    func restartCurrentLevel() {
        if gameMode == .title || gameMode == .finished {
            startNewGame()
        } else {
            loadLevel(levelIndex, keepScore: true)
            gameMode = .levelCard
            modeTimer = 1.2
        }
    }

    func setPlayerName(_ name: String) {
        let cleanedName = Renderer.cleanPlayerName(name)
        playerName = cleanedName
        UserDefaults.standard.set(cleanedName, forKey: SaveKey.playerName)
    }

    static func savedPlayerNameForPrompt() -> String {
        savedPlayerName()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let aspect = Float(size.width / max(size.height, 1))
        worldHeight = targetWorldHeight
        worldWidth = worldHeight * max(aspect, 1.0)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let deltaTime = min(Float(now - lastFrameTime), 1.0 / 20.0)
        lastFrameTime = now

        update(deltaTime: deltaTime)
        statusHandler?(statusText)

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        var vertices: [GameVertex] = []
        buildSceneVertices(in: view, into: &vertices)

        guard !vertices.isEmpty,
              let vertexBuffer = device.makeBuffer(bytes: vertices,
                                                   length: vertices.count * MemoryLayout<GameVertex>.stride,
                                                   options: .storageModeShared),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.label = "Dave1 Render Encoder"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private var statusText: String {
        switch gameMode {
        case .title:
            return "PLAYER \(playerName)  |  HIGH \(highScore)  |  PRESS ANY GAME KEY"
        case .levelCard:
            return "PLAYER \(playerName)  |  STAGE \(levelIndex + 1)  \(level.definition.name)  |  HIGH \(highScore)"
        case .paused:
            return "PAUSED | P RESUME | M SETTINGS | R RESTART"
        case .settings:
            return "SETTINGS | F SOUND \(soundEnabled ? "ON" : "OFF") | R RESET SCORES | P BACK"
        case .gameOver:
            return "GAME OVER | PLAYER \(playerName) | SCORE \(score) | PRESS SPACE/F FOR NEW GAME"
        case .finished:
            return "SCOREBOARD | PLAYER \(playerName) | FINAL \(score) | HIGH \(highScore) | PRESS R FOR NEW GAME"
        case .playing:
            let trophyText = trophyCollected ? "CUP" : "NO CUP"
            let boostPercent = Int(boostFuel * 100)
            return "\(playerName) | SCORE \(score) | HIGH \(highScore) | STAGE \(levelIndex + 1) | LIVES \(lives) | NOS \(boostPercent)% N/S/DOWN | \(trophyText)"
        }
    }

    private func update(deltaTime: Float) {
        animationTime += deltaTime
        projectileCooldown = max(0, projectileCooldown - deltaTime)
        updateFloatingLabels(deltaTime: deltaTime)

        switch gameMode {
        case .title, .finished, .paused, .settings, .gameOver:
            return
        case .levelCard:
            modeTimer -= deltaTime
            if modeTimer <= 0 {
                gameMode = .playing
            }
            return
        case .playing:
            break
        }

        let acceleration: Float = 3200
        let maxSpeed: Float = 190
        let friction: Float = onGround ? 2600 : 900

        if wantsLeft == wantsRight {
            velocity.x = approach(velocity.x, target: 0, amount: friction * deltaTime)
        } else if wantsLeft {
            velocity.x = max(velocity.x - acceleration * deltaTime, -maxSpeed)
            facingRight = false
        } else if wantsRight {
            velocity.x = min(velocity.x + acceleration * deltaTime, maxSpeed)
            facingRight = true
        }

        if wantsJump && !previousJump && jumpsRemaining > 0 {
            velocity.y = onGround ? 445 : 390
            onGround = false
            jumpsRemaining -= 1
            playSound(named: jumpsRemaining == 1 ? "Funk" : "Tink")
        }
        previousJump = wantsJump

        velocity.y -= 1050 * deltaTime
        if isBoosting {
            velocity.y += 1180 * deltaTime
            velocity.y = min(velocity.y, 310)
            boostFuel = max(0, boostFuel - 0.62 * deltaTime)
            playBoostSoundIfNeeded()
        }
        velocity.y = max(velocity.y, -700)

        movePlayerX(velocity.x * deltaTime)
        movePlayerY(velocity.y * deltaTime)
        playFootstepIfNeeded()
        updateProjectiles(deltaTime: deltaTime)
        updateEnemies(deltaTime: deltaTime)
        collectItems()
        checkDamageAndExit()
        updateCamera()
    }

    private func movePlayerX(_ amount: Float) {
        player.x += amount
        guard collidesSolid(player) else { return }

        if amount > 0 {
            let tile = Int(floor(player.maxX / tileSize))
            player.x = Float(tile) * tileSize - player.width - 0.01
        } else if amount < 0 {
            let tile = Int(floor(player.minX / tileSize))
            player.x = Float(tile + 1) * tileSize + 0.01
        }
        velocity.x = 0
    }

    private func movePlayerY(_ amount: Float) {
        player.y += amount
        onGround = false
        guard collidesSolid(player) else { return }

        if amount > 0 {
            let tile = Int(floor(player.maxY / tileSize))
            player.y = Float(tile) * tileSize - player.height - 0.01
        } else if amount < 0 {
            let tile = Int(floor(player.minY / tileSize))
            player.y = Float(tile + 1) * tileSize + 0.01
            onGround = true
            jumpsRemaining = 2
        }
        velocity.y = 0
    }

    private func updateEnemies(deltaTime: Float) {
        for index in level.enemies.indices {
            var enemy = level.enemies[index]
            switch enemy.kind {
            case .walker:
                enemy.rect.x += enemy.direction * enemy.speed * deltaTime
            case .floater:
                enemy.rect.x += enemy.direction * enemy.speed * deltaTime
                enemy.rect.y = enemy.originY + sin(animationTime * 2.5 + enemy.rect.x * 0.03) * 22
            }

            let frontX = enemy.direction > 0 ? enemy.rect.maxX + 2 : enemy.rect.minX - 2
            let footY = enemy.rect.minY - 4
            let frontTile = TilePoint(x: Int(floor(frontX / tileSize)), y: Int(floor(footY / tileSize)))

            if collidesSolid(enemy.rect) || (enemy.kind == .walker && !level.solidTiles.contains(frontTile)) {
                enemy.direction *= -1
                enemy.rect.x += enemy.direction * enemy.speed * deltaTime * 2
            }

            level.enemies[index] = enemy
        }
    }

    private func collectItems() {
        var collectedCoins: [TilePoint] = []
        let pickupRect = Rect(x: player.x - 8, y: player.y - 8, width: player.width + 16, height: player.height + 16)

        for coin in level.coins {
            let rect = Rect(x: Float(coin.x) * tileSize + 4, y: Float(coin.y) * tileSize + 4, width: 24, height: 24)
            if pickupRect.intersects(rect) {
                collectedCoins.append(coin)
            }
        }

        for coin in collectedCoins {
            level.coins.remove(coin)
            addScore(100)
            addFloatingLabel("+100 GEM", at: coin)
            playSound(named: "Pop")
        }

        var collectedBoosts: [TilePoint] = []
        for boost in level.boostPickups {
            let rect = Rect(x: Float(boost.x) * tileSize + 4, y: Float(boost.y) * tileSize + 4, width: 24, height: 24)
            if pickupRect.intersects(rect) {
                collectedBoosts.append(boost)
            }
        }

        for boost in collectedBoosts {
            level.boostPickups.remove(boost)
            boostFuel = maxBoostFuel
            addScore(150)
            addFloatingLabel("NOS FULL", at: boost)
            playSound(named: "Bottle")
        }

        var collectedSecrets: [TilePoint] = []
        for secret in level.secretBonuses {
            let rect = Rect(x: Float(secret.x) * tileSize + 4, y: Float(secret.y) * tileSize + 4, width: 24, height: 24)
            if pickupRect.intersects(rect) {
                collectedSecrets.append(secret)
            }
        }

        for secret in collectedSecrets {
            level.secretBonuses.remove(secret)
            addScore(1000)
            addFloatingLabel("SECRET +1000", at: secret)
            playSound(named: "Hero")
        }

        if let trophy = level.trophy, !trophyCollected {
            let rect = Rect(x: Float(trophy.x) * tileSize + 3, y: Float(trophy.y) * tileSize + 3, width: 26, height: 26)
            if pickupRect.intersects(rect) {
                trophyCollected = true
                addScore(500)
                addFloatingLabel("+500 CUP", at: trophy)
                playSound(named: "Glass")
            }
        }
    }

    private func checkDamageAndExit() {
        if player.minY < -tileSize || touchesHazard(player) || touchesWater(player) || level.enemies.contains(where: { player.intersects($0.rect) }) {
            loseLife()
            return
        }

        if trophyCollected, let exit = level.exit {
            let exitRect = Rect(x: Float(exit.x) * tileSize + 4, y: Float(exit.y) * tileSize, width: 24, height: 42)
            if player.intersects(exitRect) {
                advanceLevel()
            }
        }
    }

    private func loseLife() {
        playSound(named: "Basso")
        lives -= 1
        if lives <= 0 {
            submitScore()
            gameMode = .gameOver
            lives = 3
            levelIndex = 0
            return
        }
        loadLevel(levelIndex, keepScore: true)
        gameMode = .levelCard
        modeTimer = 1.2
    }

    private func advanceLevel() {
        if levelIndex == levels.count - 1 {
            addScore(1000)
            saveHighScoreIfNeeded()
            submitScore()
            playSound(named: "Hero")
            gameMode = .finished
            modeTimer = 0
        } else {
            addScore(250)
            playSound(named: "Tink")
            loadLevel(levelIndex + 1, keepScore: true)
            gameMode = .levelCard
            modeTimer = 1.4
        }
    }

    private func startNewGame() {
        score = 0
        lives = 3
        loadLevel(0, keepScore: true)
        gameMode = .levelCard
        modeTimer = 1.6
    }

    private func addScore(_ points: Int) {
        score += points
        saveHighScoreIfNeeded()
    }

    private func fireProjectile() {
        guard gameMode == .playing, projectileCooldown <= 0 else { return }
        let direction: Float = facingRight ? 1 : -1
        let startX = facingRight ? player.maxX + 2 : player.minX - 10
        let startY = player.y + 17
        projectiles.append(Projectile(rect: Rect(x: startX, y: startY, width: 10, height: 4), velocityX: direction * 430))
        projectileCooldown = 0.28
        playSound(named: "Submarine")
    }

    private func updateProjectiles(deltaTime: Float) {
        for index in projectiles.indices {
            projectiles[index].rect.x += projectiles[index].velocityX * deltaTime
        }

        var removedProjectiles: Set<Int> = []
        var removedEnemies: Set<Int> = []

        for (projectileIndex, projectile) in projectiles.enumerated() {
            if collidesSolid(projectile.rect) || projectile.rect.maxX < cameraX - 64 || projectile.rect.minX > cameraX + worldWidth + 64 {
                removedProjectiles.insert(projectileIndex)
                continue
            }

            for (enemyIndex, enemy) in level.enemies.enumerated() where projectile.rect.intersects(enemy.rect) {
                removedProjectiles.insert(projectileIndex)
                removedEnemies.insert(enemyIndex)
                addScore(enemy.kind == .floater ? 300 : 200)
                addFloatingLabel(enemy.kind == .floater ? "+300" : "+200", at: enemy.rect)
                playSound(named: "Blow")
                break
            }
        }

        projectiles = projectiles.enumerated().compactMap { removedProjectiles.contains($0.offset) ? nil : $0.element }
        level.enemies = level.enemies.enumerated().compactMap { removedEnemies.contains($0.offset) ? nil : $0.element }
    }

    private func addFloatingLabel(_ text: String, at tile: TilePoint) {
        addFloatingLabel(text, at: Rect(x: Float(tile.x) * tileSize, y: Float(tile.y) * tileSize, width: tileSize, height: tileSize))
    }

    private func addFloatingLabel(_ text: String, at rect: Rect) {
        floatingLabels.append(FloatingLabel(text: text, position: SIMD2<Float>(rect.minX, rect.maxY + 8), timeRemaining: 1.4))
    }

    private func updateFloatingLabels(deltaTime: Float) {
        for index in floatingLabels.indices {
            floatingLabels[index].position.y += 18 * deltaTime
            floatingLabels[index].timeRemaining -= deltaTime
        }
        floatingLabels.removeAll { $0.timeRemaining <= 0 }
    }

    private func playFootstepIfNeeded() {
        guard onGround, abs(velocity.x) > 45 else { return }
        guard animationTime - lastFootstepTime > 0.24 else { return }
        lastFootstepTime = animationTime
        playSound(named: "Morse")
    }

    private var isBoosting: Bool {
        wantsBoost && boostFuel > 0.02
    }

    private func playBoostSoundIfNeeded() {
        guard animationTime - lastBoostSoundTime > 0.18 else { return }
        lastBoostSoundTime = animationTime
        playSound(named: "Purr")
    }

    private func playSound(named name: String) {
        guard soundEnabled else { return }
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = 0.45
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func handleSettingsKey(_ key: InputKey) {
        switch key {
        case .shoot:
            soundEnabled.toggle()
            UserDefaults.standard.set(soundEnabled, forKey: SaveKey.soundEnabled)
            playSound(named: "Pop")
        case .pause, .settings:
            gameMode = settingsReturnMode
        case .down:
            scoreEntries = []
            highScore = 0
            UserDefaults.standard.removeObject(forKey: SaveKey.scoreEntries)
            UserDefaults.standard.set(0, forKey: SaveKey.highScore)
        default:
            break
        }
    }

    private func saveHighScoreIfNeeded() {
        guard score > highScore else { return }
        highScore = score
        UserDefaults.standard.set(highScore, forKey: SaveKey.highScore)
        UserDefaults.standard.set(playerName, forKey: SaveKey.playerName)
    }

    private func submitScore() {
        guard score > 0 else { return }
        scoreEntries.append(ScoreEntry(name: playerName, score: score))
        scoreEntries.sort { $0.score > $1.score }
        scoreEntries = Array(scoreEntries.prefix(5))
        saveScoreEntries()
    }

    private func saveScoreEntries() {
        if let data = try? JSONEncoder().encode(scoreEntries) {
            UserDefaults.standard.set(data, forKey: SaveKey.scoreEntries)
        }
    }

    private func loadLevel(_ index: Int, keepScore: Bool) {
        levelIndex = index
        level = Renderer.parse(level: levels[index])
        player = Rect(x: level.start.x, y: level.start.y, width: 22, height: 28)
        velocity = SIMD2<Float>(0, 0)
        onGround = false
        previousJump = false
        jumpsRemaining = 2
        boostFuel = 0
        projectiles.removeAll()
        floatingLabels.removeAll()
        trophyCollected = false
        cameraX = 0
        if !keepScore {
            score = 0
            lives = 3
        }
    }

    private func updateCamera() {
        let levelPixelWidth = Float(level.width) * tileSize
        let desired = player.centerX - worldWidth * 0.45
        cameraX = min(max(desired, 0), max(0, levelPixelWidth - worldWidth))
    }

    private func collidesSolid(_ rect: Rect) -> Bool {
        let minX = Int(floor(rect.minX / tileSize))
        let maxX = Int(floor((rect.maxX - 1) / tileSize))
        let minY = Int(floor(rect.minY / tileSize))
        let maxY = Int(floor((rect.maxY - 1) / tileSize))

        for y in minY...maxY {
            for x in minX...maxX where isSolid(x: x, y: y) {
                return true
            }
        }
        return false
    }

    private func isSolid(x: Int, y: Int) -> Bool {
        if x < 0 || x >= level.width || y < 0 { return true }
        if y >= level.height { return false }
        return level.solidTiles.contains(TilePoint(x: x, y: y))
    }

    private func touchesHazard(_ rect: Rect) -> Bool {
        let minX = Int(floor(rect.minX / tileSize))
        let maxX = Int(floor((rect.maxX - 1) / tileSize))
        let minY = Int(floor(rect.minY / tileSize))
        let maxY = Int(floor((rect.maxY - 1) / tileSize))

        for y in minY...maxY {
            for x in minX...maxX where level.hazardTiles.contains(TilePoint(x: x, y: y)) {
                return true
            }
        }
        return false
    }

    private func touchesWater(_ rect: Rect) -> Bool {
        if isBoosting { return false }

        let minX = Int(floor(rect.minX / tileSize))
        let maxX = Int(floor((rect.maxX - 1) / tileSize))
        let minY = Int(floor(rect.minY / tileSize))
        let maxY = Int(floor((rect.maxY - 1) / tileSize))

        for y in minY...maxY {
            for x in minX...maxX where level.waterTiles.contains(TilePoint(x: x, y: y)) {
                return true
            }
        }
        return false
    }

    private func buildSceneVertices(in view: MTKView, into vertices: inout [GameVertex]) {
        addWorldRect(Rect(x: cameraX, y: 0, width: worldWidth, height: worldHeight), color: SIMD4<Float>(0.0, 0.0, 0.0, 1), to: &vertices)
        drawDOSBackdrop(to: &vertices)

        switch gameMode {
        case .title:
            drawTitleCard(to: &vertices)
            return
        case .levelCard:
            drawLevelCard(to: &vertices)
            return
        case .paused:
            drawPauseCard(to: &vertices)
            return
        case .settings:
            drawSettingsCard(to: &vertices)
            return
        case .gameOver:
            drawGameOverCard(to: &vertices)
            return
        case .finished:
            drawFinishCard(to: &vertices)
            return
        case .playing:
            break
        }

        for tile in level.solidTiles {
            drawBlock(at: tile, to: &vertices)
        }

        for tile in level.hazardTiles {
            drawHazard(at: tile, to: &vertices)
        }

        for tile in level.waterTiles {
            drawWater(at: tile, to: &vertices)
        }

        for tile in level.coins {
            drawCoin(at: tile, to: &vertices)
        }

        for tile in level.boostPickups {
            drawBoostPickup(at: tile, to: &vertices)
        }

        for tile in level.secretBonuses {
            drawSecretBonus(at: tile, to: &vertices)
        }

        if let trophy = level.trophy, !trophyCollected {
            drawTrophy(at: trophy, to: &vertices)
        }

        if let exit = level.exit {
            drawExit(at: exit, to: &vertices)
        }

        for enemy in level.enemies {
            drawEnemy(enemy, to: &vertices)
        }

        for projectile in projectiles {
            drawProjectile(projectile, to: &vertices)
        }

        drawPlayer(to: &vertices)
        drawFloatingLabels(to: &vertices)
        drawStatusBoard(to: &vertices)
    }

    private func drawStatusBoard(to vertices: inout [GameVertex]) {
        let x = cameraX + 8
        let y = worldHeight - 58
        let boardWidth = min(worldWidth - 16, 760)
        let boardColor = SIMD4<Float>(0.08, 0.045, 0.03, 1)
        let edgeColor = SIMD4<Float>(0.76, 0.42, 0.16, 1)
        addWorldRect(Rect(x: x, y: y, width: boardWidth, height: 48), color: edgeColor, to: &vertices)
        addWorldRect(Rect(x: x + 4, y: y + 4, width: boardWidth - 8, height: 40), color: boardColor, to: &vertices)

        let scoreX = x + 18
        let highX = x + 158
        let boostX = x + 298
        let stageX = min(x + 426, x + boardWidth - 255)
        let lifeX = x + boardWidth - 148
        let cupX = x + boardWidth - 48

        drawScoreMeter(x: scoreX, y: y + 16, value: score, color: SIMD4<Float>(0.04, 0.78, 0.20, 1), to: &vertices)
        drawScoreMeter(x: highX, y: y + 16, value: highScore, color: SIMD4<Float>(1.0, 0.72, 0.08, 1), to: &vertices)
        drawBoostMeter(x: boostX, y: y + 16, to: &vertices)
        drawStagePips(x: stageX, y: y + 14, to: &vertices)
        drawLifeIcons(x: lifeX, y: y + 11, to: &vertices)
        drawMiniCup(x: cupX, y: y + 12, lit: trophyCollected, to: &vertices)
    }

    private func drawScoreMeter(x: Float, y: Float, value: Int, color: SIMD4<Float>, to vertices: inout [GameVertex]) {
        let clampedValue = min(value, 9999)
        let filled = min(10, clampedValue / 100)
        for index in 0..<10 {
            let segmentColor = index < filled ? color : SIMD4<Float>(0.16, 0.12, 0.09, 1)
            addWorldRect(Rect(x: x + Float(index) * 11, y: y, width: 8, height: 16), color: segmentColor, to: &vertices)
        }
    }

    private func drawBoostMeter(x: Float, y: Float, to vertices: inout [GameVertex]) {
        let filled = Int(round(boostFuel * 8))
        for index in 0..<8 {
            let isFilled = index < filled
            let color = isFilled ? SIMD4<Float>(0.05, 0.62, 1.0, 1) : SIMD4<Float>(0.06, 0.10, 0.16, 1)
            addWorldRect(Rect(x: x + Float(index) * 11, y: y, width: 8, height: 16), color: color, to: &vertices)
        }
    }

    private func drawStagePips(x: Float, y: Float, to vertices: inout [GameVertex]) {
        for index in 0..<levels.count {
            let isCurrent = index == levelIndex
            let isComplete = index < levelIndex
            let color = isCurrent ? SIMD4<Float>(0.05, 0.36, 0.92, 1) : (isComplete ? SIMD4<Float>(0.04, 0.78, 0.20, 1) : SIMD4<Float>(0.16, 0.12, 0.09, 1))
            addWorldRect(Rect(x: x + Float(index) * 10, y: y, width: 7, height: isCurrent ? 20 : 12), color: color, to: &vertices)
        }
    }

    private func drawLifeIcons(x: Float, y: Float, to vertices: inout [GameVertex]) {
        for index in 0..<3 {
            let color = index < lives ? SIMD4<Float>(0.05, 0.36, 0.92, 1) : SIMD4<Float>(0.13, 0.08, 0.06, 1)
            addWorldRect(Rect(x: x + Float(index) * 22, y: y, width: 14, height: 18), color: color, to: &vertices)
            addWorldRect(Rect(x: x + Float(index) * 22 + 4, y: y + 18, width: 8, height: 7), color: index < lives ? SIMD4<Float>(0.96, 0.68, 0.45, 1) : SIMD4<Float>(0.13, 0.08, 0.06, 1), to: &vertices)
        }
    }

    private func drawMiniCup(x: Float, y: Float, lit: Bool, to vertices: inout [GameVertex]) {
        let color = lit ? SIMD4<Float>(1.0, 0.73, 0.05, 1) : SIMD4<Float>(0.20, 0.14, 0.05, 1)
        addWorldRect(Rect(x: x + 5, y: y + 8, width: 14, height: 10), color: color, to: &vertices)
        addWorldRect(Rect(x: x + 10, y: y + 3, width: 4, height: 7), color: color, to: &vertices)
        addWorldRect(Rect(x: x + 6, y: y, width: 12, height: 4), color: color, to: &vertices)
    }

    private func drawTitleCard(to vertices: inout [GameVertex]) {
        let panelX = cameraX + worldWidth * 0.5 - 190
        drawCardPanel(x: panelX, y: 108, width: 380, height: 250, to: &vertices)
        drawBlockLogo(x: panelX + 54, y: 288, scale: 12, to: &vertices)
        drawText("RETRO DAVE RUN", x: panelX + 60, y: 214, scale: 3, color: SIMD4<Float>(1.0, 0.74, 0.12, 1), to: &vertices)
        drawText("M SETTINGS", x: panelX + 86, y: 178, scale: 3, color: SIMD4<Float>(0.05, 0.62, 1.0, 1), to: &vertices)
        let blink = sin(animationTime * 5) > 0
        if blink {
            drawText("PRESS ANY KEY", x: panelX + 72, y: 142, scale: 3, color: SIMD4<Float>(0.04, 0.78, 0.20, 1), to: &vertices)
        }
        drawTrophy(at: TilePoint(x: Int((panelX + 52) / tileSize), y: 4), to: &vertices)
        drawHazard(at: TilePoint(x: Int((panelX + 292) / tileSize), y: 4), to: &vertices)
    }

    private func drawLevelCard(to vertices: inout [GameVertex]) {
        let panelX = cameraX + worldWidth * 0.5 - 170
        drawCardPanel(x: panelX, y: 130, width: 340, height: 205, to: &vertices)
        drawText("LEVEL \(levelIndex + 1)", x: panelX + 74, y: 296, scale: 4, color: SIMD4<Float>(1.0, 0.74, 0.12, 1), to: &vertices)
        drawText(level.definition.name.uppercased(), x: panelX + 44, y: 252, scale: 3, color: SIMD4<Float>(0.05, 0.62, 1.0, 1), to: &vertices)
        drawText("GET CUP", x: panelX + 44, y: 214, scale: 3, color: SIMD4<Float>(0.04, 0.78, 0.20, 1), to: &vertices)
        drawText("THEN DOOR", x: panelX + 44, y: 184, scale: 3, color: SIMD4<Float>(0.94, 0.08, 0.04, 1), to: &vertices)
        drawPlayerPreview(x: panelX + 252, y: 152, to: &vertices)
    }

    private func drawPauseCard(to vertices: inout [GameVertex]) {
        let panelX = cameraX + worldWidth * 0.5 - 160
        drawCardPanel(x: panelX, y: 155, width: 320, height: 150, to: &vertices)
        drawText("PAUSED", x: panelX + 72, y: 262, scale: 5, color: SIMD4<Float>(1.0, 0.74, 0.12, 1), to: &vertices)
        drawText("P RESUME", x: panelX + 58, y: 220, scale: 3, color: SIMD4<Float>(0.04, 0.78, 0.20, 1), to: &vertices)
        drawText("M SETTINGS", x: panelX + 58, y: 190, scale: 3, color: SIMD4<Float>(0.05, 0.62, 1.0, 1), to: &vertices)
    }

    private func drawSettingsCard(to vertices: inout [GameVertex]) {
        let panelX = cameraX + worldWidth * 0.5 - 190
        drawCardPanel(x: panelX, y: 130, width: 380, height: 220, to: &vertices)
        drawText("SETTINGS", x: panelX + 72, y: 308, scale: 4, color: SIMD4<Float>(1.0, 0.74, 0.12, 1), to: &vertices)
        drawText("F SOUND \(soundEnabled ? "ON" : "OFF")", x: panelX + 52, y: 260, scale: 3, color: SIMD4<Float>(0.04, 0.78, 0.20, 1), to: &vertices)
        drawText("DOWN RESET SCORE", x: panelX + 52, y: 226, scale: 3, color: SIMD4<Float>(0.94, 0.08, 0.04, 1), to: &vertices)
        drawText("P BACK", x: panelX + 52, y: 192, scale: 3, color: SIMD4<Float>(0.05, 0.62, 1.0, 1), to: &vertices)
    }

    private func drawGameOverCard(to vertices: inout [GameVertex]) {
        let panelX = cameraX + worldWidth * 0.5 - 190
        drawCardPanel(x: panelX, y: 120, width: 380, height: 230, to: &vertices)
        drawText("GAME OVER", x: panelX + 56, y: 306, scale: 4, color: SIMD4<Float>(0.94, 0.08, 0.04, 1), to: &vertices)
        drawText(playerName, x: panelX + 54, y: 258, scale: 3, color: SIMD4<Float>(1.0, 0.74, 0.12, 1), to: &vertices)
        drawText("SCORE \(score)", x: panelX + 54, y: 224, scale: 3, color: SIMD4<Float>(0.04, 0.78, 0.20, 1), to: &vertices)
        drawText("SPACE NEW GAME", x: panelX + 54, y: 182, scale: 3, color: SIMD4<Float>(0.05, 0.62, 1.0, 1), to: &vertices)
    }

    private func drawFinishCard(to vertices: inout [GameVertex]) {
        let panelX = cameraX + worldWidth * 0.5 - 200
        drawCardPanel(x: panelX, y: 100, width: 400, height: 270, to: &vertices)
        drawBlockLogo(x: panelX + 64, y: 288, scale: 11, to: &vertices)
        drawText(playerName, x: panelX + 70, y: 260, scale: 3, color: SIMD4<Float>(1.0, 0.74, 0.12, 1), to: &vertices)
        drawScoreMeter(x: panelX + 72, y: 236, value: score, color: SIMD4<Float>(0.04, 0.78, 0.20, 1), to: &vertices)
        drawScoreMeter(x: panelX + 214, y: 236, value: highScore, color: SIMD4<Float>(1.0, 0.72, 0.08, 1), to: &vertices)
        drawStagePips(x: panelX + 148, y: 160, to: &vertices)
        drawScoreboard(x: panelX + 70, y: 102, to: &vertices)
        for index in 0..<7 {
            let x = panelX + 56 + Float(index) * 44
            let y = 195 + sin(animationTime * 4 + Float(index)) * 12
            addWorldRect(Rect(x: x, y: y, width: 26, height: 26), color: SIMD4<Float>(1.0, 0.72, 0.08, 1), to: &vertices)
            addWorldRect(Rect(x: x + 8, y: y + 8, width: 10, height: 10), color: SIMD4<Float>(1.0, 0.94, 0.42, 1), to: &vertices)
        }
        let blink = sin(animationTime * 4) > 0
        if blink {
            addWorldRect(Rect(x: panelX + 94, y: 126, width: 212, height: 12), color: SIMD4<Float>(0.04, 0.78, 0.20, 1), to: &vertices)
        }
    }

    private func drawScoreboard(x: Float, y: Float, to vertices: inout [GameVertex]) {
        for (index, entry) in scoreEntries.prefix(3).enumerated() {
            drawText("\(index + 1) \(entry.name) \(entry.score)", x: x, y: y - Float(index) * 18, scale: 2, color: SIMD4<Float>(0.85, 0.82, 0.62, 1), to: &vertices)
        }
    }

    private func drawCardPanel(x: Float, y: Float, width: Float, height: Float, to vertices: inout [GameVertex]) {
        addWorldRect(Rect(x: x, y: y, width: width, height: height), color: SIMD4<Float>(0.55, 0.32, 0.16, 1), to: &vertices)
        addWorldRect(Rect(x: x + 8, y: y + 8, width: width - 16, height: height - 16), color: SIMD4<Float>(0.08, 0.05, 0.04, 1), to: &vertices)
        addWorldRect(Rect(x: x, y: y + height - 8, width: width, height: 8), color: SIMD4<Float>(0.90, 0.54, 0.22, 1), to: &vertices)
        addWorldRect(Rect(x: x, y: y, width: width, height: 8), color: SIMD4<Float>(0.20, 0.10, 0.05, 1), to: &vertices)
    }

    private func drawBlockLogo(x: Float, y: Float, scale: Float, to vertices: inout [GameVertex]) {
        let colors = [SIMD4<Float>(0.05, 0.34, 0.95, 1), SIMD4<Float>(1.0, 0.75, 0.08, 1), SIMD4<Float>(0.93, 0.08, 0.04, 1), SIMD4<Float>(0.05, 0.82, 0.24, 1)]
        let columns: [[Int]] = [
            [1, 1, 1, 0, 1, 1, 1],
            [1, 0, 1, 0, 1, 0, 1],
            [1, 0, 1, 0, 1, 1, 0],
            [1, 0, 1, 0, 1, 0, 1],
            [1, 1, 1, 0, 1, 1, 1]
        ]
        for column in 0..<columns.count {
            for row in 0..<columns[column].count where columns[column][row] == 1 {
                addWorldRect(Rect(x: x + Float(column) * scale * 2, y: y - Float(row) * scale, width: scale, height: scale), color: colors[column % colors.count], to: &vertices)
            }
        }
    }

    private func drawPlayerPreview(x: Float, y: Float, to vertices: inout [GameVertex]) {
        let oldPlayer = player
        player = Rect(x: x, y: y, width: 22, height: 28)
        drawPlayer(to: &vertices)
        player = oldPlayer
    }

    private func drawText(_ text: String, x: Float, y: Float, scale: Float, color: SIMD4<Float>, to vertices: inout [GameVertex]) {
        var cursorX = x
        for character in text.uppercased() {
            if character == " " {
                cursorX += scale * 4
                continue
            }
            drawGlyph(character, x: cursorX, y: y, scale: scale, color: color, to: &vertices)
            cursorX += scale * 6
        }
    }

    private func drawGlyph(_ character: Character, x: Float, y: Float, scale: Float, color: SIMD4<Float>, to vertices: inout [GameVertex]) {
        let rows = Renderer.glyphRows(for: character)
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<5 where (row & (1 << (4 - column))) != 0 {
                addWorldRect(Rect(x: x + Float(column) * scale, y: y - Float(rowIndex) * scale, width: scale, height: scale), color: color, to: &vertices)
            }
        }
    }

    private func drawDOSBackdrop(to vertices: inout [GameVertex]) {
        let gridColor = SIMD4<Float>(0.02, 0.03, 0.08, 1)
        let startColumn = Int(floor(cameraX / tileSize))
        let endColumn = Int(ceil((cameraX + worldWidth) / tileSize))

        for column in startColumn...endColumn where column % 4 == 0 {
            let x = Float(column) * tileSize
            addWorldRect(Rect(x: x, y: 0, width: 2, height: worldHeight), color: gridColor, to: &vertices)
        }

        for row in 0...Int(worldHeight / tileSize) where row % 3 == 0 {
            let y = Float(row) * tileSize
            addWorldRect(Rect(x: cameraX, y: y, width: worldWidth, height: 2), color: gridColor, to: &vertices)
        }
    }

    private func drawBlock(at tile: TilePoint, to vertices: inout [GameVertex]) {
        let x = Float(tile.x) * tileSize
        let y = Float(tile.y) * tileSize
        let base = ((tile.x + tile.y) % 2 == 0) ? SIMD4<Float>(0.44, 0.19, 0.10, 1) : SIMD4<Float>(0.36, 0.15, 0.08, 1)
        let light = SIMD4<Float>(0.86, 0.42, 0.18, 1)
        let shadow = SIMD4<Float>(0.10, 0.04, 0.04, 1)
        let mortar = SIMD4<Float>(0.03, 0.02, 0.025, 1)

        addWorldRect(Rect(x: x, y: y, width: tileSize, height: tileSize), color: base, to: &vertices)
        addWorldRect(Rect(x: x, y: y + tileSize - 3, width: tileSize, height: 3), color: light, to: &vertices)
        addWorldRect(Rect(x: x, y: y, width: tileSize, height: 3), color: shadow, to: &vertices)
        addWorldRect(Rect(x: x, y: y + 15, width: tileSize, height: 2), color: mortar, to: &vertices)
        addWorldRect(Rect(x: x + 15, y: y + 16, width: 2, height: 14), color: mortar, to: &vertices)
        addWorldRect(Rect(x: x + 4, y: y + 1, width: 2, height: 14), color: mortar, to: &vertices)
    }

    private func drawHazard(at tile: TilePoint, to vertices: inout [GameVertex]) {
        let x = Float(tile.x) * tileSize
        let y = Float(tile.y) * tileSize
        let flicker = sin(animationTime * 16 + Float(tile.x)) * 3
        addWorldRect(Rect(x: x, y: y, width: tileSize, height: 5), color: SIMD4<Float>(0.36, 0.02, 0.01, 1), to: &vertices)
        addTriangle(SIMD2<Float>(x + 1, y + 4), SIMD2<Float>(x + 8, y + 29 + flicker), SIMD2<Float>(x + 15, y + 4), color: SIMD4<Float>(0.95, 0.05, 0.02, 1), to: &vertices)
        addTriangle(SIMD2<Float>(x + 9, y + 4), SIMD2<Float>(x + 16, y + 24 - flicker), SIMD2<Float>(x + 23, y + 4), color: SIMD4<Float>(1.0, 0.45, 0.02, 1), to: &vertices)
        addTriangle(SIMD2<Float>(x + 17, y + 4), SIMD2<Float>(x + 25, y + 30 + flicker), SIMD2<Float>(x + 31, y + 4), color: SIMD4<Float>(0.95, 0.05, 0.02, 1), to: &vertices)
    }

    private func drawWater(at tile: TilePoint, to vertices: inout [GameVertex]) {
        let x = Float(tile.x) * tileSize
        let y = Float(tile.y) * tileSize
        let wave = sin(animationTime * 5 + Float(tile.x)) * 3
        addWorldRect(Rect(x: x, y: y, width: tileSize, height: tileSize), color: SIMD4<Float>(0.02, 0.12, 0.50, 1), to: &vertices)
        addWorldRect(Rect(x: x, y: y + 21 + wave, width: 12, height: 4), color: SIMD4<Float>(0.20, 0.74, 1.0, 1), to: &vertices)
        addWorldRect(Rect(x: x + 12, y: y + 17 - wave, width: 12, height: 4), color: SIMD4<Float>(0.10, 0.46, 0.95, 1), to: &vertices)
        addWorldRect(Rect(x: x + 24, y: y + 21 + wave, width: 8, height: 4), color: SIMD4<Float>(0.20, 0.74, 1.0, 1), to: &vertices)
    }

    private func drawCoin(at tile: TilePoint, to vertices: inout [GameVertex]) {
        let x = Float(tile.x) * tileSize
        let y = Float(tile.y) * tileSize + sin(animationTime * 5 + Float(tile.x)) * 3
        let red = SIMD4<Float>(0.95, 0.05, 0.05, 1)
        let shine = SIMD4<Float>(1.0, 0.78, 0.56, 1)
        addWorldRect(Rect(x: x + 10, y: y + 7, width: 12, height: 18), color: red, to: &vertices)
        addWorldRect(Rect(x: x + 8, y: y + 11, width: 16, height: 10), color: red, to: &vertices)
        addWorldRect(Rect(x: x + 13, y: y + 24, width: 6, height: 4), color: SIMD4<Float>(0.45, 0.02, 0.02, 1), to: &vertices)
        addWorldRect(Rect(x: x + 13, y: y + 14, width: 3, height: 5), color: shine, to: &vertices)
    }

    private func drawTrophy(at tile: TilePoint, to vertices: inout [GameVertex]) {
        let x = Float(tile.x) * tileSize
        let y = Float(tile.y) * tileSize + sin(animationTime * 3) * 2
        let gold = SIMD4<Float>(1.0, 0.73, 0.05, 1)
        let darkGold = SIMD4<Float>(0.58, 0.28, 0.02, 1)
        addWorldRect(Rect(x: x + 8, y: y + 13, width: 16, height: 12), color: gold, to: &vertices)
        addWorldRect(Rect(x: x + 5, y: y + 17, width: 5, height: 7), color: gold, to: &vertices)
        addWorldRect(Rect(x: x + 22, y: y + 17, width: 5, height: 7), color: gold, to: &vertices)
        addWorldRect(Rect(x: x + 13, y: y + 7, width: 6, height: 7), color: darkGold, to: &vertices)
        addWorldRect(Rect(x: x + 8, y: y + 4, width: 16, height: 4), color: gold, to: &vertices)
        addWorldRect(Rect(x: x + 12, y: y + 20, width: 5, height: 3), color: SIMD4<Float>(1, 0.95, 0.45, 1), to: &vertices)
    }

    private func drawExit(at tile: TilePoint, to vertices: inout [GameVertex]) {
        let x = Float(tile.x) * tileSize + 3
        let y = Float(tile.y) * tileSize
        let openColor = trophyCollected ? SIMD4<Float>(0.02, 0.72, 0.16, 1) : SIMD4<Float>(0.10, 0.16, 0.24, 1)
        addWorldRect(Rect(x: x, y: y, width: 26, height: 44), color: SIMD4<Float>(0.38, 0.18, 0.06, 1), to: &vertices)
        addWorldRect(Rect(x: x + 4, y: y + 4, width: 18, height: 36), color: openColor, to: &vertices)
        addWorldRect(Rect(x: x + 17, y: y + 22, width: 4, height: 4), color: SIMD4<Float>(1.0, 0.75, 0.12, 1), to: &vertices)
    }

    private func drawEnemy(_ enemy: Enemy, to vertices: inout [GameVertex]) {
        let bob = sin(animationTime * 8 + enemy.rect.x * 0.04) * 2
        let rect = Rect(x: enemy.rect.x, y: enemy.rect.y + bob, width: enemy.rect.width, height: enemy.rect.height)
        let step: Float = sin(animationTime * 14 + enemy.rect.x * 0.04) > 0 ? 2 : -2
        let bodyColor = enemy.kind == .floater ? SIMD4<Float>(0.48, 0.04, 0.82, 1) : SIMD4<Float>(0.65, 0.02, 0.09, 1)
        addWorldRect(rect, color: bodyColor, to: &vertices)
        addWorldRect(Rect(x: rect.x + 2, y: rect.y + 5, width: 22, height: 5), color: SIMD4<Float>(0.25, 0.0, 0.03, 1), to: &vertices)
        addWorldRect(Rect(x: rect.x + 5, y: rect.y + 15, width: 5, height: 4), color: SIMD4<Float>(1, 0.85, 0.58, 1), to: &vertices)
        addWorldRect(Rect(x: rect.x + 16, y: rect.y + 15, width: 5, height: 4), color: SIMD4<Float>(1, 0.85, 0.58, 1), to: &vertices)
        addWorldRect(Rect(x: rect.x + 5 + step, y: rect.y - 2, width: 5, height: 4), color: SIMD4<Float>(0.92, 0.65, 0.35, 1), to: &vertices)
        addWorldRect(Rect(x: rect.x + 17 - step, y: rect.y - 2, width: 5, height: 4), color: SIMD4<Float>(0.92, 0.65, 0.35, 1), to: &vertices)
    }

    private func drawProjectile(_ projectile: Projectile, to vertices: inout [GameVertex]) {
        addWorldRect(projectile.rect, color: SIMD4<Float>(1.0, 0.88, 0.18, 1), to: &vertices)
        let tailX = projectile.velocityX > 0 ? projectile.rect.minX - 6 : projectile.rect.maxX
        addWorldRect(Rect(x: tailX, y: projectile.rect.y + 1, width: 6, height: 2), color: SIMD4<Float>(0.94, 0.08, 0.04, 1), to: &vertices)
    }

    private func drawBoostPickup(at tile: TilePoint, to vertices: inout [GameVertex]) {
        let x = Float(tile.x) * tileSize
        let y = Float(tile.y) * tileSize + sin(animationTime * 4 + Float(tile.x)) * 2
        addWorldRect(Rect(x: x + 8, y: y + 6, width: 16, height: 22), color: SIMD4<Float>(0.05, 0.62, 1.0, 1), to: &vertices)
        addWorldRect(Rect(x: x + 11, y: y + 21, width: 10, height: 4), color: SIMD4<Float>(0.80, 0.94, 1.0, 1), to: &vertices)
        addWorldRect(Rect(x: x + 13, y: y + 9, width: 6, height: 8), color: SIMD4<Float>(0.02, 0.12, 0.50, 1), to: &vertices)
    }

    private func drawSecretBonus(at tile: TilePoint, to vertices: inout [GameVertex]) {
        let x = Float(tile.x) * tileSize
        let y = Float(tile.y) * tileSize + sin(animationTime * 6) * 3
        addWorldRect(Rect(x: x + 7, y: y + 7, width: 18, height: 18), color: SIMD4<Float>(0.04, 0.78, 0.20, 1), to: &vertices)
        addWorldRect(Rect(x: x + 12, y: y + 12, width: 8, height: 8), color: SIMD4<Float>(1.0, 0.94, 0.42, 1), to: &vertices)
    }

    private func drawFloatingLabels(to vertices: inout [GameVertex]) {
        for label in floatingLabels {
            drawText(label.text, x: label.position.x, y: label.position.y, scale: 2, color: SIMD4<Float>(1.0, 0.94, 0.42, 1), to: &vertices)
        }
    }

    private func drawPlayer(to vertices: inout [GameVertex]) {
        let blue = SIMD4<Float>(0.02, 0.24, 0.86, 1)
        let darkBlue = SIMD4<Float>(0.0, 0.05, 0.35, 1)
        let skin = SIMD4<Float>(0.96, 0.68, 0.45, 1)
        let hair = SIMD4<Float>(0.32, 0.12, 0.02, 1)
        let running = abs(velocity.x) > 20 && onGround
        let stride: Float = running ? (sin(animationTime * 18) > 0 ? 3 : -3) : 0
        let headBob: Float = running ? abs(sin(animationTime * 18)) * 2 : 0
        let faceOffset: Float = facingRight ? 15 : 5

        addWorldRect(Rect(x: player.x + 4 + stride, y: player.y, width: 6, height: 8), color: darkBlue, to: &vertices)
        addWorldRect(Rect(x: player.x + 14 - stride, y: player.y, width: 6, height: 8), color: darkBlue, to: &vertices)
        addWorldRect(Rect(x: player.x + 5, y: player.y + 8, width: 14, height: 12), color: blue, to: &vertices)
        addWorldRect(Rect(x: player.x + 2, y: player.y + 13 - stride * 0.5, width: 5, height: 10), color: skin, to: &vertices)
        addWorldRect(Rect(x: player.x + 17, y: player.y + 13 + stride * 0.5, width: 5, height: 10), color: skin, to: &vertices)
        addWorldRect(Rect(x: player.x + 6, y: player.y + 20 + headBob, width: 12, height: 8), color: skin, to: &vertices)
        addWorldRect(Rect(x: player.x + 5, y: player.y + 26 + headBob, width: 14, height: 4), color: hair, to: &vertices)
        addWorldRect(Rect(x: player.x + 3, y: player.y + 28 + headBob, width: 18, height: 3), color: blue, to: &vertices)
        addWorldRect(Rect(x: player.x + faceOffset, y: player.y + 23 + headBob, width: 3, height: 3), color: SIMD4<Float>(0, 0, 0, 1), to: &vertices)

        if isBoosting {
            let flame = sin(animationTime * 22) > 0 ? SIMD4<Float>(0.05, 0.62, 1.0, 1) : SIMD4<Float>(1.0, 0.82, 0.12, 1)
            addTriangle(SIMD2<Float>(player.x + 7, player.y - 2), SIMD2<Float>(player.x + 12, player.y - 18), SIMD2<Float>(player.x + 17, player.y - 2), color: flame, to: &vertices)
        }
    }

    private func addWorldRect(_ rect: Rect, color: SIMD4<Float>, to vertices: inout [GameVertex]) {
        let min = worldToClip(SIMD2<Float>(rect.minX, rect.minY))
        let max = worldToClip(SIMD2<Float>(rect.maxX, rect.maxY))

        let a = SIMD2<Float>(min.x, min.y)
        let b = SIMD2<Float>(max.x, min.y)
        let c = SIMD2<Float>(max.x, max.y)
        let d = SIMD2<Float>(min.x, max.y)

        vertices.append(GameVertex(position: a, color: color))
        vertices.append(GameVertex(position: b, color: color))
        vertices.append(GameVertex(position: c, color: color))
        vertices.append(GameVertex(position: a, color: color))
        vertices.append(GameVertex(position: c, color: color))
        vertices.append(GameVertex(position: d, color: color))
    }

    private func addTriangle(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, color: SIMD4<Float>, to vertices: inout [GameVertex]) {
        vertices.append(GameVertex(position: worldToClip(a), color: color))
        vertices.append(GameVertex(position: worldToClip(b), color: color))
        vertices.append(GameVertex(position: worldToClip(c), color: color))
    }

    private func worldToClip(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let x = ((point.x - cameraX) / worldWidth) * 2 - 1
        let y = (point.y / worldHeight) * 2 - 1
        return SIMD2<Float>(x, y)
    }

    private func approach(_ value: Float, target: Float, amount: Float) -> Float {
        if value < target { return min(value + amount, target) }
        return max(value - amount, target)
    }

    private static func savedPlayerName() -> String {
        cleanPlayerName(UserDefaults.standard.string(forKey: SaveKey.playerName) ?? NSUserName())
    }

    private static func cleanPlayerName(_ name: String) -> String {
        let allowedCharacters = name.uppercased().filter { character in
            character.isLetter || character.isNumber || character == " " || character == "_"
        }
        let trimmedName = String(allowedCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "PLAYER" : String(trimmedName.prefix(12))
    }

    private static func loadScoreEntries() -> [ScoreEntry] {
        guard let data = UserDefaults.standard.data(forKey: SaveKey.scoreEntries),
              let entries = try? JSONDecoder().decode([ScoreEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func glyphRows(for character: Character) -> [Int] {
        switch character {
        case "0": return [0b11111, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b11111]
        case "1": return [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110]
        case "2": return [0b11110, 0b00001, 0b00001, 0b11110, 0b10000, 0b10000, 0b11111]
        case "3": return [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110]
        case "4": return [0b10010, 0b10010, 0b10010, 0b11111, 0b00010, 0b00010, 0b00010]
        case "5": return [0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110]
        case "6": return [0b01111, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110]
        case "7": return [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000]
        case "8": return [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110]
        case "9": return [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b11110]
        case "A": return [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001]
        case "B": return [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110]
        case "C": return [0b01111, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111]
        case "D": return [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110]
        case "E": return [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111]
        case "F": return [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000]
        case "G": return [0b01111, 0b10000, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111]
        case "H": return [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001]
        case "I": return [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111]
        case "J": return [0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100]
        case "K": return [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001]
        case "L": return [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111]
        case "M": return [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001]
        case "N": return [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001]
        case "O": return [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110]
        case "P": return [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000]
        case "Q": return [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101]
        case "R": return [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001]
        case "S": return [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110]
        case "T": return [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100]
        case "U": return [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110]
        case "V": return [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100]
        case "W": return [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010]
        case "X": return [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001]
        case "Y": return [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100]
        case "Z": return [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111]
        case "+": return [0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000]
        case "-": return [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000]
        default: return [0b11111, 0b10001, 0b00010, 0b00100, 0b00100, 0b00000, 0b00100]
        }
    }

    private static func parse(level definition: LevelDefinition) -> LevelState {
        var state = LevelState(definition: definition)
        state.height = definition.rows.count
        state.width = definition.rows.map { $0.count }.max() ?? 0

        for (rowIndex, row) in definition.rows.enumerated() {
            let y = state.height - rowIndex - 1
            for (x, character) in row.enumerated() {
                let tile = TilePoint(x: x, y: y)
                switch character {
                case "#", "=":
                    state.solidTiles.insert(tile)
                case "^":
                    state.hazardTiles.insert(tile)
                case "~":
                    state.waterTiles.insert(tile)
                case "C":
                    state.coins.insert(tile)
                case "B":
                    state.boostPickups.insert(tile)
                case "?":
                    state.secretBonuses.insert(tile)
                case "T":
                    state.trophy = tile
                case "X":
                    state.exit = tile
                case "E":
                    let rect = Rect(x: Float(x) * tileSize + 3, y: Float(y) * tileSize, width: 26, height: 22)
                    state.enemies.append(Enemy(rect: rect, direction: -1, speed: 75, kind: .walker, originY: rect.y))
                case "F":
                    let rect = Rect(x: Float(x) * tileSize + 3, y: Float(y) * tileSize + 8, width: 26, height: 22)
                    state.enemies.append(Enemy(rect: rect, direction: -1, speed: 55, kind: .floater, originY: rect.y))
                case "S":
                    state.start = SIMD2<Float>(Float(x) * tileSize + 5, Float(y) * tileSize)
                default:
                    break
                }
            }
        }

        return state
    }

    private static func makeLevels() -> [LevelDefinition] {
        [
            LevelDefinition(name: "Easy Start", rows: [
                "....................................................",
                "....................................................",
                "....................................................",
                "....................................................",
                "....................................................",
                "........................................T...........",
                "....................................########........",
                "....................C....B....C.....................",
                "..............########....########..................",
                ".......C........................................X...",
                "....########.........................############...",
                "..S..................E..............................",
                "##############################......................",
                "####################################################"
            ]),
            LevelDefinition(name: "Small Steps", rows: [
                "....................................................",
                "....................................................",
                "....................................................",
                "....................................................",
                ".......................................T............",
                "...................................########.........",
                ".........................C..........................",
                ".....................########.......................",
                ".............C........B...................C.....X...",
                ".........########...............########.....########",
                "..S.................................................",
                "############....................############........",
                "############........................................",
                "####################################################"
            ]),
            LevelDefinition(name: "First Guard", rows: [
                "....................................................",
                "....................................................",
                "....................................................",
                "........................................T...........",
                "....................................########........",
                ".......................C..........?.................",
                "...................########.........................",
                ".........C.............................C............",
                ".....########.............E.........########.....X..",
                "........................########..............######",
                "..S.................................................",
                "################..................################..",
                "################....................................",
                "####################################################"
            ]),
            LevelDefinition(name: "Tiny Fire", rows: [
                "....................................................",
                "....................................................",
                "....................................................",
                "........................................T...........",
                "....................................########........",
                "....................C........B......................",
                "................########............................",
                ".........C.........................C.............X..",
                ".....########..................########......########",
                "........................F..........................",
                "..S.................................................",
                "###############....~~....###############...........",
                "###############..........###############...........",
                "####################################################"
            ]),
            LevelDefinition(name: "Practice Hall", rows: [
                "....................................................",
                "....................................................",
                "..........................................T.........",
                "....................................................",
                "............................C.......................",
                "........................########....................",
                "................C..........................C....X...",
                "............########..............########.....######",
                ".....C................B.............................",
                "..########.................E........................",
                "..S.................................................",
                "####################...~~~~~~...##############.....",
                "####################..........################.....",
                "####################################################"
            ]),
            LevelDefinition(name: "Gentle Climb", rows: [
                "....................................................",
                "....................................................",
                "........................................T...........",
                "....................................########........",
                "..........................C.............C...........",
                "......................########......................",
                "..............C..........................C......X...",
                "..........########..............########......#######",
                ".....C................B.............................",
                "..########.............E............................",
                "..S.................................................",
                "################...~~~~~~...##############.........",
                "################..........################.........",
                "####################################################"
            ]),
            LevelDefinition(name: "Wide Bridge", rows: [
                "....................................................",
                "....................................................",
                ".........................................T..........",
                "....................................................",
                ".........................C............C.............",
                ".....................########.......................",
                "............C..............................C....X...",
                "........########...............#########......######",
                "........................F..........................",
                "..S.................................................",
                "###############...~~~~~~...##########....^^........",
                "###############..........############..............",
                "####################################################"
            ]),
            LevelDefinition(name: "Two Guards", rows: [
                "....................................................",
                "....................................................",
                "..........................................T.........",
                "....................................................",
                "........................C.......?.......C...........",
                "....................########.......................",
                "............C.....................C.............X...",
                "........########......E......########......#########",
                ".................................E..................",
                "..S.................................................",
                "################...~~~~~~...##############.........",
                "################..........################.........",
                "####################################################"
            ]),
            LevelDefinition(name: "Cup Walk", rows: [
                "....................................................",
                "....................................................",
                "..........................................T.........",
                "......................................########......",
                "..............................C.....................",
                "..........................########..................",
                ".................C..........................C...X...",
                "............########..............########.....######",
                ".....C.....................E........................",
                "..########..........................................",
                "..S.................................................",
                "#################...~~~~~~...#############.........",
                "#################..........###############.........",
                "####################################################"
            ]),
            LevelDefinition(name: "Final Easy", rows: [
                "....................................................",
                "....................................................",
                ".........................................T..........",
                "....................................................",
                "........................C.......?.......C...........",
                "....................########.......................",
                "...........C......................C.............X...",
                ".......########......E.......########......#########",
                "....................................................",
                "..S.................................................",
                "###############...~~~~~~...#########....^^.........",
                "###############..........###########...............",
                "####################################################"
            ])
        ]
    }
}
