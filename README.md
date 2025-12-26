#  QBridge

QBridge is a modern, lightweight native bridge for iOS that lets you build hybrid apps using idiomatic Swift, while exposing only the native APIs you explicitly choose to JavaScript.

It is designed as a clean, native-first alternative to Cordova and Capacitor, without legacy constraints, global magic, or opaque runtime behavior.

[Qbix](https://qbix.com), the company behind QBridge, designs web-first applications. [Get in touch](https://qbix.com/about) if you need help or would like to collaborate with us. We've released our entire module platform as open-source to help developers. You're welcome:

| Area | Software | Description |
|---|---|---|
| iOS | [QBridge](https://qbix.com) | Helps you easily make your web apps hybrid/native. Learn why you should be building [serverless web apps](https://qbix.com/blog/2020/01/02/the-case-for-building-client-first-web-apps/). |
| Web Front End | [Q.js](https://github.com/Qbix/Q.js) | A modern, modular alternative to React/Angular/Vue. `Q.minimal.js` weighs ~40KB and can be dropped into any web app. |
| Web Full Stack | [Qbix Platform](https://qbix.com/platform) | A battle-tested, modular framework for launching full sites (even build your own Facebook / LinkedIn). Explore this only after you built a serverless web app.
| AI | [AI Agents](http://engageusers.ai/ecosystem.pdf) | Working on an AI Agency to make all this easy to configure for non-developers starting in 2026 |

---

## 🌉 What QBridge Is

| Concept | What it means |
|------|-------------|
| Native-first | You write real Swift, not adapters around adapters |
| Explicit API surface | Only methods you expose are callable from JS |
| WKWebView-native | Built directly on WKWebView, no extra runtime |
| Extension-safe | Works in apps, App Clips, and Share Extensions |
| Minimal bridge | No plugin XML, no manifests, no global JS soup |

---

## 🧱 How QBridge Works (High Level)

| Step | Description |
|----|------------|
| 1 | QBridge attaches to a WKWebView |
| 2 | JavaScript sends structured messages via WKScriptMessageHandler |
| 3 | Messages are routed by service + action |
| 4 | Swift methods are invoked directly |
| 5 | Results are returned via a callback ID |

There is no polling, no hidden lifecycle, and no background JavaScript runtime.

---

## 📐Core Design Principles

| Principle | Why it matters |
|---------|----------------|
| Single bridge instance | Predictable behavior, easy debugging |
| Message-based routing | Clear mental model |
| Obj-C compatible selectors | Zero Swift/JS impedance mismatch |
| Thread-safe execution | Native work happens off the main thread |
| Explicit callbacks | No promises disappearing into the void |

---

## 🆚 QBridge vs Cordova vs Capacitor

| Feature | QBridge | Cordova | Capacitor |
|------|--------|---------|-----------|
| Write plugins in Swift | Yes | No | Partial |
| Expose only selected methods | Yes | No | Partial |
| Plugin discovery | Compile-time | Runtime | Runtime |
| WebView storage durability | Solved natively | Fragile | Fragile |
| IndexedDB backed by SQLite | Built-in | No | No |
| App Clips / Extensions | First-class | Unsupported | Limited |
| JS bridge size | Minimal | Large | Medium |
| Debuggability | High | Low | Medium |

Cordova and Capacitor try to hide native.
QBridge embraces native and makes it safe.

---

## 🚀 Getting Started

### Add QBridge to Your Xcode Project

| Step | Action |
|----|-------|
| 1 | Add the QBridge Swift files to your app target |
| 2 | Include them in App / App Clip / Extension targets as needed |
| 3 | No CocoaPods, no CLI tools, no config files |

### Attach QBridge to a WKWebView

Swift:

```swift
let webView = WKWebView(frame: .zero)
QBridge.shared.attach(to: webView)
```

### Send Messages from JavaScript

JavaScript:

```javascript
window.webkit.messageHandlers.QBridge.postMessage({
  service: "DeviceBridgePlugin",
  action: "info",
  args: [],
  callbackId: "cb1"
});
```

### Receive Results in JavaScript

```javascript
window.QBridge = {
  onNative(payload) {
    console.log(payload.data);
  }
};
```

### Write Your First Plugin

Swift:

```swift
@objc class MyPlugin: QBridgeBaseService {
  @objc func hello(_ args: Any?, callbackId: String?) {
    bridge.sendEvent(callbackId ?? "", data: ["message": "Hello from Swift"])
  }
}
```

---

# 🧩 Plugins

The plugins below are production-grade, written in idiomatic Swift, and designed to solve real problems in hybrid apps. Like continuing to use the same storage Web APIs you're already used to (IndexedDB and localStorage) but have them actually continue to work in your app. Use the same code on the Web and in your app!

They are listed in order of importance.

---

## Persistent Web Storage (localStorage Backup)

*🕴"It would be a shame if your app's storage was suddenly deleted."*

| Problem | Reality on iOS |
|------|----------------|
| WebView localStorage | Can be purged |
| IndexedDB | Can disappear |
| Silent data loss | Happens in production |

| Capability | Description |
|-----------|-------------|
| Load storage | Restores saved localStorage on launch |
| Save deltas | Writes changes to disk |
| File-backed | Uses real files you control |
| Session tracking | Detects fresh vs restored sessions |

---

## IndexedDB (SQLite-backed, Native)

| IndexedDB Feature | WebView Reality |
|-----------------|----------------|
| Object stores | Opaque |
| Indexes | Opaque |
| Persistence | Unreliable |
| Backups | Impossible |

| Feature | Implementation |
|-------|---------------|
| IndexedDB-style API | JavaScript-compatible |
| SQLite backend | Real .sqlite files |
| Versioned upgrades | Deterministic |
| Indexes & cursors | Native-speed |
| Import / export | Supported |
| Native toggle | Optional |

---

## Secure Identity & Signing

| Capability | Why it exists |
|----------|---------------|
| Secure Enclave keys | Hardware-backed identity |
| App Attest fallback | Works in App Clips |
| Continuity | Identity survives upgrades |
| Payload signing | Anti-fraud, trust |

---

## Clipboard Access

| Feature | Why |
|------|-----|
| Read clipboard | User workflows |
| Write clipboard | Sharing |
| Native permissions | Predictable behavior |

---

## Device Information

| Data | Use case |
|----|----------|
| Model | Debugging |
| OS version | Feature gating |
| Name | Diagnostics |

---

## Share Extensions (Email & SMS)

| Problem | Solution |
|------|----------|
| JS can’t close extensions | Native completion |
| Broken share flows | Fixed |
| Attachments | Supported |

---

## View / Extension Closer

| Context | Behavior |
|-------|----------|
| App UI | Dismiss controller |
| Extension UI | Complete request |
| Fallback | Safe default |

---

## Contacts & Address Book

| Capability | Notes |
|---------|------|
| Permissions | Correctly handled |
| Read contacts | Structured |
| Groups | Supported |
| Native picker | Included |
| Add / update / delete | Full lifecycle |

---

## Final Notes

QBridge is intentionally small, explicit, and honest.

If you want predictable storage, strong security, App Clips support, and clean Swift-native plugins, QBridge is the modern choice.
