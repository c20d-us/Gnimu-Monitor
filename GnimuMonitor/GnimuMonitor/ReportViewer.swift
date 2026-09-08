// Gnimu Monitor
// Copyright (C) 2026 Chris Halstead
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Combine
import SwiftUI
import WebKit

/// A report chosen for viewing.
struct ReportSelection: Identifiable, Sendable, Codable, Hashable {
    let id: String
    let url: URL
    let title: String
}

/// Shows one report full-bleed, with only the chrome needed to leave and share.
///
/// The report is a self-contained page, so this is a plain local file load —
/// nothing is fetched. SFSafariViewController can't be used here: it only
/// accepts http/https and refuses file URLs.
struct ReportViewer: View {
    let selection: ReportSelection
    @Environment(\.dismiss) private var dismiss

    /// Nil until the file is confirmed present — an evicted iCloud report has
    /// to be pulled back down before WebKit can open it.
    @State private var readyURL: URL?
    @State private var failure: String?
    @StateObject private var proxy = ReportWebProxy()

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            content
        }
        .task {
            proxy.jobName = selection.title
            await prepare()
        }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            barContent
            if let message = proxy.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { proxy.errorMessage = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(.bar)
    }

    private var barContent: some View {
        HStack(spacing: 12) {
            #if os(iOS)
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
            #endif

            Spacer()

            Text(selection.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // The page has its own Print button, but a native one is here too:
            // it's the discoverable place, and it works before the page loads.
            Button { proxy.printReport() } label: {
                Image(systemName: "printer")
            }
            .buttonStyle(.bordered)
            .disabled(readyURL == nil)
            .help("Print or save as PDF")

            // Sharing belongs here as well as in the list: you often decide to
            // send a report only once you've looked at it.
            ShareLink(item: selection.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let readyURL {
            ReportWebView(url: readyURL, proxy: proxy)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Opening report…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Makes sure the file is actually on disk before handing it to WebKit,
    /// which would otherwise just render blank for an evicted iCloud report.
    private func prepare() async {
        let url = selection.url
        let available = await Task.detached(priority: .userInitiated) { () -> Bool in
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) { return true }

            try? fm.startDownloadingUbiquitousItem(at: url)
            // Bounded: a download that never lands should report a failure
            // rather than spin forever.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if fm.fileExists(atPath: url.path) { return true }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return false
        }.value

        if available {
            readyURL = url
        } else {
            failure = "This report is stored in iCloud and couldn't be downloaded."
        }
    }
}

/// Holds the live web view so the toolbar can drive it, and answers the page's
/// print request.
///
/// `WKWebView.createPDF` renders with screen CSS, so it would ignore the
/// report's print stylesheet entirely. Native printing is what actually applies
/// `@media print` — and on both platforms the print flow is also how you save a
/// PDF.
final class ReportWebProxy: NSObject, ObservableObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var jobName: String = "Capture Analysis"
    /// Printing fails in ways worth showing rather than swallowing — a missing
    /// sandbox entitlement looks identical to a dead button otherwise.
    @Published var errorMessage: String?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.body as? String == "print" else { return }
        printReport()
    }

    func printReport() {
        guard let webView else { return }
        #if os(iOS)
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = jobName
        // Matches the report's @page rule so the dialog opens on the
        // orientation the layout was designed for.
        info.orientation = .landscape
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = webView.viewPrintFormatter()

        let completion: UIPrintInteractionController.CompletionHandler = { [weak self] _, _, error in
            if let error { self?.errorMessage = error.localizedDescription }
        }
        // iPad presents the print panel as a popover and needs an anchor; the
        // unanchored call is iPhone-only and fails there.
        if UIDevice.current.userInterfaceIdiom == .pad,
           let window = UIApplication.shared.connectedScenes
               .compactMap({ $0 as? UIWindowScene })
               .first(where: { $0.activationState == .foregroundActive })?.keyWindow {
            let anchor = CGRect(x: window.bounds.maxX - 90, y: 54, width: 1, height: 1)
            controller.present(from: anchor, in: window, animated: true,
                               completionHandler: completion)
        } else {
            controller.present(animated: true, completionHandler: completion)
        }
        #else
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = .landscape
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = true
        let operation = webView.printOperation(with: info)
        operation.jobTitle = jobName
        operation.view?.frame = webView.bounds
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
        #endif
    }
}

/// Wraps `WKWebView` for both platforms.
///
/// Loading happens in the coordinator rather than in `update…`, which SwiftUI
/// calls repeatedly — reloading there would throw away the reader's scroll
/// position and any chart zoom every time the view updated.
private struct ReportWebView {
    let url: URL
    let proxy: ReportWebProxy

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // The report is one self-contained file; nothing should be persisted.
        config.websiteDataStore = .nonPersistent()
        // The page's own Print button posts here when it finds the bridge.
        config.userContentController.add(proxy, name: "gnimuReport")
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        web.scrollView.contentInsetAdjustmentBehavior = .always
        #endif
        proxy.webView = web
        return web
    }

    func load(_ web: WKWebView, coordinator: Coordinator) {
        guard coordinator.loaded != url else { return }
        coordinator.loaded = url
        // Read access scoped to the file itself: the page has no subresources,
        // so there's no reason to expose its whole directory.
        web.loadFileURL(url, allowingReadAccessTo: url)
    }

    final class Coordinator {
        var loaded: URL?
    }
}

#if os(iOS)
extension ReportWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ web: WKWebView, context: Context) {
        load(web, coordinator: context.coordinator)
    }
}
#else
extension ReportWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ web: WKWebView, context: Context) {
        load(web, coordinator: context.coordinator)
    }
}
#endif
