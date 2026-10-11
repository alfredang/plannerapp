import Foundation
import SwiftData

/// One report page published by a Digital Workforce agent (Mac: ~/DigitalWorkforce). The Mac
/// uploads each page here so it syncs through iCloud and the iPhone can read it.
///
/// CloudKit requirements honoured: every property has a default, no unique constraints.
@Model
final class AgentReport {
    var id: UUID = UUID()
    /// The page's file name, e.g. "2026-10-11-oracle-updates.html" — the identity of a report.
    var file: String = ""
    var title: String = ""
    var agent: String = ""
    /// yyyy-MM-dd, so reports sort and group by day without date parsing.
    var dateKey: String = ""
    var summary: String = ""
    var html: String = ""
    var contentHash: String = ""
    var modifiedAt: Date = Date()

    init(file: String) { self.file = file }
}

/// Alfred's reply under one card of a report. The Mac appends every reply (its own and the
/// iPhone's) to ~/DigitalWorkforce/replies/replies.jsonl, which the agents read each run.
@Model
final class ReportReply {
    var id: UUID = UUID()
    /// The report file the card is on.
    var page: String = ""
    /// The card's first ~90 characters of text — how a reply is tied to its card.
    var item: String = ""
    var text: String = ""
    var createdAt: Date = Date()
    /// "mac" or "iphone".
    var source: String = ""

    init(page: String, item: String, text: String, source: String) {
        self.page = page; self.item = item; self.text = text; self.source = source
    }
}

/// The page script that puts a compact "💬 Reply" link under every card (`.item`) of a
/// report. Shared by the Mac browser tab and the iPhone report viewer; both receive
/// `{page, item, text}` on the `reply` message handler and call `__plShow(saved)` after load.
enum ReportReplyScript {
    static let source = """
    (function () {
      if (!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.reply)) return;
      var page = window.__plPage || location.pathname.split('/').pop();
      var st = document.createElement('style');
      st.textContent = '.pl-reply{grid-column:2;font:13px -apple-system,sans-serif;margin:0}.pl-link{color:#3949c8;cursor:pointer;font-weight:600;font-size:12px;background:none;border:0;padding:0}.pl-form{display:none;gap:6px;margin-top:4px}.pl-form.open{display:flex}.pl-form input{flex:1;min-width:0;padding:4px 8px;border:1px solid #c9ced6;border-radius:6px;font:inherit}.pl-form button{padding:4px 12px;border:0;border-radius:6px;background:#3949c8;color:#fff;font:600 12px -apple-system,sans-serif;cursor:pointer}.pl-saved{margin-top:3px;padding:3px 8px;border-radius:6px;background:#e8f4ec;color:#1d5c34;font-size:12px;white-space:pre-wrap}';
      document.head.appendChild(st);
      function key(el) { return (el.innerText || '').replace(/\\\\s+/g, ' ').trim().slice(0, 90); }
      window.__plShow = function (saved) {
        document.querySelectorAll('.item').forEach(function (el) {
          if (el.querySelector('.pl-reply') || el.closest('.exec')) return;
          var k = key(el), box = document.createElement('div'); box.className = 'pl-reply';
          var link = document.createElement('button'); link.className = 'pl-link'; link.textContent = '💬 Reply';
          var form = document.createElement('div'); form.className = 'pl-form';
          var ta = document.createElement('input'); ta.placeholder = 'Reply to the agents…';
          var btn = document.createElement('button'); btn.textContent = 'Send';
          var out = document.createElement('div');
          link.onclick = function () { form.classList.toggle('open'); if (form.classList.contains('open')) ta.focus(); };
          function note(t) { var d = document.createElement('div'); d.className = 'pl-saved'; d.textContent = '✓ You: ' + t; out.appendChild(d); }
          saved.filter(function (r) { return r.item === k; }).forEach(function (r) { note(r.text); });
          function send() {
            var t = ta.value.trim(); if (!t) return;
            window.webkit.messageHandlers.reply.postMessage({ page: page, item: k, text: t });
            note(t); ta.value = ''; form.classList.remove('open');
          }
          btn.onclick = send;
          ta.onkeydown = function (e) { if (e.key === 'Enter') send(); };
          form.appendChild(ta); form.appendChild(btn);
          box.appendChild(out); box.appendChild(link); box.appendChild(form); el.appendChild(box);
        });
      };
    })();
    """
}
