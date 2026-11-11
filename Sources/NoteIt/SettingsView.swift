import AppKit
import SwiftUI

/// Native toolbar-style Settings window: General, AI, Actions, and Sync.
@MainActor
enum SettingsWindow {
  enum Tab: Int { case general, ai, actions, sync }

  private static var controller: NSWindowController?
  private static var tabs: NSTabViewController?

  static func show(tab: Tab? = nil) {
    if controller == nil {
      let t = NSTabViewController()
      t.tabStyle = .toolbar
      t.canPropagateSelectedChildViewControllerTitle = true
      t.addTabViewItem(item("General", "gearshape", GeneralPane()))
      t.addTabViewItem(item("AI", "sparkles", AIPane()))
      t.addTabViewItem(item("Actions", "list.bullet.rectangle", ActionsPane()))
      t.addTabViewItem(item("Sync", "arrow.triangle.2.circlepath.icloud", SyncPane()))
      let w = NSWindow(contentViewController: t)
      w.styleMask = [.titled, .closable]
      w.toolbarStyle = .preference
      w.isReleasedWhenClosed = false
      w.center()
      w.setFrameAutosaveName("NoteIt.Settings")
      tabs = t
      controller = NSWindowController(window: w)
    }
    if let tab { tabs?.selectedTabViewItemIndex = tab.rawValue }
    NSApp.activate()
    controller?.showWindow(nil)
    controller?.window?.makeKeyAndOrderFront(nil)
  }

  private static func item(_ label: String, _ icon: String, _ view: some View) -> NSTabViewItem {
    let host = NSHostingController(rootView: view.environment(Prefs.shared))
    host.sizingOptions = [.preferredContentSize]
    host.title = label
    let i = NSTabViewItem(viewController: host)
    i.label = label
    i.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)
    return i
  }
}

private func pane(@ViewBuilder _ content: () -> some View) -> some View {
  Form { content() }
    .formStyle(.grouped)
    .frame(width: 560)
    .fixedSize(horizontal: false, vertical: true)
}

// MARK: General

private struct GeneralPane: View {
  @Environment(Prefs.self) private var prefs
  @State private var login = Prefs.shared.launchAtLogin

  var body: some View {
    @Bindable var prefs = prefs
    pane {
      Section("New Notes") {
        Picker("Color", selection: $prefs.defaultColor) {
          ForEach(NoteColor.allCases, id: \.self) { c in
            Label {
              Text(c.title)
            } icon: {
              Image(nsImage: c.swatch(14))
            }
            .tag(c)
          }
        }
        LabeledContent("Font") {
          HStack {
            Text(fontLabel).foregroundStyle(.secondary)
            Button("Choose…") { FontPicker.shared.open() }
          }
        }
        Toggle("Float on top of other windows", isOn: $prefs.newNotesFloat)
      }
      Section("Notes") {
        LabeledContent("Translucency") {
          Slider(value: $prefs.translucency, in: 0.3...0.95) {
            EmptyView()
          } minimumValueLabel: {
            Image(systemName: "circle.dotted")
          } maximumValueLabel: {
            Image(systemName: "circle.fill")
          }
          .frame(width: 220)
        }
        Toggle("Check spelling while typing", isOn: $prefs.spellCheck)
        Toggle("Show the AI button on notes", isOn: $prefs.showAIButton)
        Toggle("Snap notes to screen edges and to each other", isOn: $prefs.snapNotes)
      }
      Section {
        Toggle("Open NoteIt at login", isOn: $login)
          .onChange(of: login) { prefs.launchAtLogin = login }
        Toggle("Press \(Hotkey.label) in any app for a new note", isOn: $prefs.quickCapture)
      }
      Section {
        Toggle("Back up all notes every day", isOn: $prefs.dailyBackups)
        HStack {
          Button("Back Up Now") {
            if let url = Backups.backUp(.shared) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          }
          Button("Restore…") { Backups.chooseAndRestore(store: .shared, texts: .shared) }
          Spacer()
          Button("Show Backups") { NSWorkspace.shared.open(Backups.dir) }
        }
      } header: {
        Text("Backups")
      } footer: {
        Text("NoteIt keeps the last \(Backups.keep) backups. Notes in the Trash are deleted for good after \(TRASH_DAYS) days.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var fontLabel: String {
    let f = prefs.font
    return "\(f.displayName ?? f.fontName) \(Int(prefs.fontSize)) pt"
  }
}

/// Opens the system font panel and stores the chosen face as the default.
@MainActor
final class FontPicker: NSObject, NSFontChanging {
  static let shared = FontPicker()

  func open() {
    let fm = NSFontManager.shared
    fm.target = self
    fm.setSelectedFont(Prefs.shared.font, isMultiple: false)
    fm.orderFrontFontPanel(nil)
  }

  func changeFont(_ sender: NSFontManager?) {
    guard let sender else { return }
    let f = sender.convert(Prefs.shared.font)
    let prefs = Prefs.shared
    prefs.fontName = f.fontName == NSFont.systemFont(ofSize: f.pointSize).fontName ? "" : f.fontName
    prefs.fontSize = Double(f.pointSize)
  }

  func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask { [.collection, .face, .size] }
}

// MARK: AI

private struct AIPane: View {
  @Environment(Prefs.self) private var prefs
  @State private var key = Keychain.key(Prefs.shared.ai.provider)
  @State private var models: [String] = []
  @State private var loading = false
  @State private var status: (ok: Bool, text: String)?
  @State private var testing = false

  private var preset: ProviderPreset { ProviderPreset.find(prefs.ai.provider) }

  var body: some View {
    @Bindable var prefs = prefs
    pane {
      Section {
        Picker("Provider", selection: Binding(get: { prefs.ai.provider }, set: { id in
          prefs.ai.use(ProviderPreset.find(id))
          key = Keychain.key(id)
          models = []
          status = nil
        })) {
          ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
        }
        if preset.id == "custom" {
          Picker("API format", selection: $prefs.ai.wire) {
            ForEach(Wire.allCases, id: \.self) { Text($0.title).tag($0) }
          }
        }
        TextField("Base URL", text: $prefs.ai.base, prompt: Text("https://example.com/v1"))
        LabeledContent("API key") {
          HStack {
            SecureField("API key", text: $key, prompt: Text(preset.needsKey ? "Required" : "Optional"))
              .labelsHidden()
              .onSubmit { Keychain.setKey(key, for: preset.id) }
              .onChange(of: key) { Keychain.setKey(key, for: preset.id) }
            if let u = preset.keyURL, let url = URL(string: u) {
              Link(destination: url) { Image(systemName: "arrow.up.forward.square") }
                .help("Get an API key")
            }
          }
        }
        LabeledContent("Model") {
          HStack {
            TextField("Model", text: $prefs.ai.model, prompt: Text("Model ID"))
              .labelsHidden()
            Menu {
              if models.isEmpty {
                Text(loading ? "Loading…" : "No models loaded")
              }
              ForEach(models, id: \.self) { m in
                Button(m) { prefs.ai.model = m }
              }
            } label: {
              Image(systemName: "list.bullet")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose from the provider's models")
            Button {
              Task { await loadModels() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .help("Fetch models")
            .disabled(loading)
          }
        }
      } header: {
        Text("Provider")
      } footer: {
        Text("Keys are stored in your macOS Keychain. Router runs on this Mac and needs no key.")
          .foregroundStyle(.secondary)
      }

      Section("Model Options") {
        if prefs.ai.wire == .anthropic {
          Picker("Effort", selection: $prefs.ai.effort) {
            Text("Model default").tag("")
            Text("Low").tag("low")
            Text("Medium").tag("medium")
            Text("High").tag("high")
          }
          Stepper("Max output tokens: \(prefs.ai.maxTokens.formatted())", value: $prefs.ai.maxTokens, in: 1_000...64_000, step: 1_000)
        }
        else {
          Toggle("Custom temperature", isOn: Binding(get: { prefs.ai.temperature != nil }, set: { prefs.ai.temperature = $0 ? 0.7 : nil }))
          if let t = prefs.ai.temperature {
            LabeledContent("Temperature") {
              HStack {
                Slider(value: Binding(get: { t }, set: { prefs.ai.temperature = ($0 * 10).rounded() / 10 }), in: 0...2)
                Text(t, format: .number.precision(.fractionLength(1)))
                  .monospacedDigit()
                  .frame(width: 28, alignment: .trailing)
              }
              .frame(width: 220)
            }
          }
        }
        Stepper("Timeout: \(Int(prefs.ai.timeout)) s", value: $prefs.ai.timeout, in: 15...600, step: 15)
      }

      Section("Behavior") {
        Picker("When the answer arrives", selection: $prefs.ai.apply) {
          ForEach(ApplyMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle("Stream the answer into the note as it's written", isOn: $prefs.ai.stream)
          .disabled(prefs.ai.apply == .review)
        LabeledContent("Instructions") {
          TextEditor(text: $prefs.ai.system)
            .font(.callout)
            .frame(height: 90)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        HStack {
          Spacer()
          Button("Restore Default Instructions") { prefs.ai.system = DEFAULT_SYSTEM }
            .disabled(prefs.ai.system == DEFAULT_SYSTEM)
        }
      }

      Section {
        HStack {
          if testing {
            ProgressView().controlSize(.small)
          }
          else if let status {
            Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
              .foregroundStyle(status.ok ? .green : .orange)
              .lineLimit(3)
          }
          Spacer()
          Button("Test Connection") { Task { await test() } }
            .disabled(testing)
        }
      }
    }
  }

  private func loadModels() async {
    loading = true
    defer { loading = false }
    do {
      models = try await AIClient.models(prefs.ai, key: key)
      status = models.isEmpty ? (false, "The provider listed no models.") : nil
    }
    catch {
      status = (false, error.localizedDescription)
    }
  }

  private func test() async {
    testing = true
    defer { testing = false }
    let action = AIAction(name: "Test", icon: "", prompt: "Reply with the word OK and nothing else.")
    do {
      let reply = try await AIClient.run(prefs.ai, key: key, user: AIClient.prompt(action, "ping")) { _ in }
      status = (true, "Connected. \(prefs.ai.model) replied “\(reply.prefix(40))”.")
    }
    catch {
      status = (false, error.localizedDescription)
    }
  }
}

// MARK: Actions

private struct ActionsPane: View {
  @Environment(Prefs.self) private var prefs
  @State private var selection: UUID?

  var body: some View {
    @Bindable var prefs = prefs
    pane {
      Section {
        Picker("Sparkles button runs", selection: Binding(get: { prefs.ai.primary?.id }, set: { prefs.ai.defaultAction = $0 })) {
          ForEach(prefs.ai.enabledActions) { a in
            Label(a.name, systemImage: a.icon).tag(Optional(a.id))
          }
        }
      } footer: {
        Text("Click ✨ on a note, or press ⌘R, to run this action. Click the chevron or right-click the note for all actions. With text selected, only the selection changes.")
          .foregroundStyle(.secondary)
      }

      Section("Actions") {
        List(selection: $selection) {
          ForEach($prefs.ai.actions) { $a in
            HStack {
              Toggle("", isOn: $a.enabled).labelsHidden()
              Image(systemName: a.icon).frame(width: 18).foregroundStyle(.secondary)
              Text(a.name)
            }
            .tag(a.id)
          }
          .onMove { prefs.ai.actions.move(fromOffsets: $0, toOffset: $1) }
        }
        .frame(height: 210)
        HStack(spacing: 0) {
          Button {
            let a = AIAction(name: "New Action", icon: "wand.and.stars", prompt: "Rewrite this note so that…")
            prefs.ai.actions.append(a)
            selection = a.id
          } label: {
            Image(systemName: "plus").frame(width: 22, height: 18)
          }
          Button {
            prefs.ai.actions.removeAll { $0.id == selection }
            selection = nil
          } label: {
            Image(systemName: "minus").frame(width: 22, height: 18)
          }
          .disabled(selection == nil)
          Spacer()
          Button("Restore Defaults") {
            prefs.ai.actions = AIAction.defaults
            prefs.ai.defaultAction = nil
            selection = nil
          }
        }
        .buttonStyle(.borderless)
      }

      if let i = prefs.ai.actions.firstIndex(where: { $0.id == selection }) {
        Section("Edit Action") {
          TextField("Name", text: $prefs.ai.actions[i].name)
          Picker("Icon", selection: $prefs.ai.actions[i].icon) {
            ForEach(ICONS, id: \.self) { Image(systemName: $0).tag($0) }
          }
          LabeledContent("Instruction") {
            TextEditor(text: $prefs.ai.actions[i].prompt)
              .font(.callout)
              .frame(height: 80)
              .scrollContentBackground(.hidden)
              .padding(4)
              .background(.background, in: RoundedRectangle(cornerRadius: 6))
              .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
          }
        }
      }
    }
  }
}

// MARK: Sync

private struct SyncPane: View {
  @State private var sync = Sync.shared
  @State private var email = Sync.shared.email
  @State private var password = ""
  @State private var busy = false
  @State private var message: (ok: Bool, text: String)?

  var body: some View {
    pane {
      if sync.signedIn {
        Section {
          LabeledContent("Account", value: sync.email)
          LabeledContent("Status") { status }
          HStack {
            Button("Sync Now") { sync.syncNow() }
              .disabled(sync.phase == .syncing)
            Spacer()
            Button("Sign Out", role: .destructive) {
              sync.signOut()
              password = ""
            }
          }
        } header: {
          Text("Sync")
        } footer: {
          Text("Notes, titles, notebooks, colors, favorites, reminders, and the Trash sync to every Mac signed in to this account. Which notes are on the desktop, and where, stays with each Mac. Signing out keeps your notes on this Mac.")
            .foregroundStyle(.secondary)
        }
      }
      else {
        Section {
          TextField("Email", text: $email, prompt: Text("you@example.com"))
            .textContentType(.username)
          SecureField("Password", text: $password, prompt: Text("At least 6 characters"))
            .textContentType(.password)
            .onSubmit { go(create: false) }
          HStack {
            if busy { ProgressView().controlSize(.small) }
            Button("Forgot Password") { reset() }
              .buttonStyle(.link)
              .disabled(email.isEmpty || busy)
            Spacer()
            Button("Create Account") { go(create: true) }
              .disabled(!ready || busy)
            Button("Sign In") { go(create: false) }
              .keyboardShortcut(.defaultAction)
              .disabled(!ready || busy)
          }
          if let message {
            Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
              .foregroundStyle(message.ok ? .green : .orange)
          }
        } header: {
          Text("Sync with Firebase")
        } footer: {
          Text("Sign in with the same account on each Mac to keep notes in step. Notes are stored in the NoteIt Firebase project (Cloud Firestore). Images larger than about 700 KB per note stay on this Mac.")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var ready: Bool { email.contains("@") && password.count >= 6 }

  @ViewBuilder private var status: some View {
    switch sync.phase {
    case .signedOut: Text("Off")
    case .syncing: HStack { ProgressView().controlSize(.small); Text("Syncing…") }
    case .idle:
      if let d = sync.lastSync { Text("Up to date · \(d.formatted(date: .omitted, time: .shortened))") } else { Text("Waiting") }
    case .failed(let m):
      Text(m).foregroundStyle(.orange).textSelection(.enabled).lineLimit(4)
    }
  }

  private func go(create: Bool) {
    guard ready, !busy else { return }
    busy = true
    message = nil
    Task {
      do {
        try await sync.signIn(email: email, password: password, create: create)
        password = ""
      }
      catch { message = (false, error.localizedDescription) }
      busy = false
    }
  }

  private func reset() {
    busy = true
    Task {
      do {
        try await sync.resetPassword(email: email)
        message = (true, "Check \(email) for a link to reset your password.")
      }
      catch { message = (false, error.localizedDescription) }
      busy = false
    }
  }
}

private let ICONS = [
  "sparkles", "wand.and.stars", "textformat.abc", "text.badge.checkmark", "arrow.down.right.and.arrow.up.left",
  "arrow.up.left.and.arrow.down.right", "text.append", "list.bullet", "checklist", "briefcase", "face.smiling",
  "character.bubble", "envelope", "lightbulb", "pencil", "quote.bubble", "number", "calendar",
]
