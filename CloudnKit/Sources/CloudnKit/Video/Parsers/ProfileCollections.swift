// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 抖音 / 快手主页批量：隐藏浏览器里钩作品列表接口 + 自动下滑翻页的共用脚本。
import Foundation

/// 主页作品列表的分页接口（抖音 aweme/post 要 a_bogus 签名，快手 GraphQL 常要验证）都交给页面自己发：
/// 文档开始前钩住 XHR / fetch，把命中接口的响应交给平台各自的 JS 处理函数累积到 window.__cloudnProfile，
/// 同时定时把页面滚到底触发下一页；readyScript 在「没有更多 / 到上限 / 超时 / 长时间无新页」时放行。
enum ProfileCollectionJS {
    /// 最多收集的作品数
    static let maxItems = 300
    /// 整体时间预算（毫秒，从文档开始算）
    static let budgetMs = 40_000
    /// 已有数据后连续这么久没有新页就收手（毫秒）
    static let stallMs = 10_000
    /// 一页都没拿到时最多等多久（毫秒）
    static let firstPageMs = 25_000
    /// 交给 WebPageExtractor 的超时（秒），要比 budgetMs 宽松
    static let extractorTimeout: TimeInterval = 60

    /// - Parameters:
    ///   - urlMarker: 请求 URL 里包含该串才处理
    ///   - handler: JS 函数体，可用变量 `S`（状态）、`root`（已解析的响应 JSON），往 S.list 推精简后的条目，
    ///     并维护 S.hasMore / S.nickname；返回 true 表示这是一页有效数据
    ///   - cardSelector: 作品卡片的 CSS 选择器，用来把最后一张卡片滚进视野（滚动容器不一定是 window）
    static func hookScript(urlMarker: String, handler: String, cardSelector: String) -> String {
        """
        (function () {
          try {
            if (window.__cloudnProfileHook) return;
            window.__cloudnProfileHook = true;
            var S = window.__cloudnProfile = { list: [], seen: {}, pages: 0, hasMore: true, nickname: '', start: Date.now(), last: Date.now(), flip: 0 };
            var accept = function (text) {
              var root = null;
              try { root = JSON.parse(text); } catch (e) { return; }
              if (!root) return;
              var ok = false;
              try { ok = (function (S, root) { \(handler) })(S, root); } catch (e) {}
              if (ok) { S.pages += 1; S.last = Date.now(); }
            };
            var keep = function (url, text) {
              if (url && String(url).indexOf(\(Self.jsString(urlMarker))) >= 0 && text) accept(text);
            };
            var rawOpen = XMLHttpRequest.prototype.open;
            var rawSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function (method, url) {
              try { this.__cloudnProfileUrl = String(url || ''); } catch (e) {}
              return rawOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function () {
              var xhr = this;
              try {
                xhr.addEventListener('load', function () {
                  if (xhr.status !== 200) return;
                  var text = '';
                  try { text = xhr.responseText || ''; } catch (e) {}
                  if (!text) { try { var r = xhr.response; if (r) text = (typeof r === 'string') ? r : JSON.stringify(r); } catch (e) {} }
                  keep(xhr.__cloudnProfileUrl, text);
                });
              } catch (e) {}
              return rawSend.apply(this, arguments);
            };
            if (window.fetch) {
              var rawFetch = window.fetch;
              window.fetch = function (input) {
                var url = (typeof input === 'string') ? input : (input && input.url) || '';
                return rawFetch.apply(this, arguments).then(function (resp) {
                  try { if (String(url).indexOf(\(Self.jsString(urlMarker))) >= 0) resp.clone().text().then(function (t) { keep(url, t); }); } catch (e) {}
                  return resp;
                });
              };
            }
            var scrollBox = function (el, bottom) {
              if (!el) return;
              var max = el.scrollHeight - el.clientHeight;
              if (max <= 0) return;
              el.scrollTop = bottom ? max : Math.max(0, max - 600);
            };
            var tick = function () {
              try {
                if (!document.body) return;
                if (!S.hasMore || S.list.length >= \(maxItems)) return;
                S.flip += 1;
                var bottom = (S.flip % 3) !== 0;
                scrollBox(document.scrollingElement || document.documentElement, bottom);
                window.scrollTo(0, bottom ? document.body.scrollHeight : Math.max(0, document.body.scrollHeight - 1200));
                var cards = document.querySelectorAll(\(Self.jsString(cardSelector)));
                if (cards.length) {
                  var lastCard = cards[cards.length - 1];
                  try { lastCard.scrollIntoView({ block: 'end' }); } catch (e) {}
                  var p = lastCard.parentElement;
                  while (p && p !== document.body) { scrollBox(p, bottom); p = p.parentElement; }
                }
                window.dispatchEvent(new Event('scroll'));
              } catch (e) {}
            };
            setInterval(tick, 1200);
          } catch (e) {}
        })();
        """
    }

    static let readyScript = """
    (function () {
      var S = window.__cloudnProfile;
      if (!S) return false;
      var now = Date.now();
      if (S.pages > 0 && !S.hasMore) return true;
      if (S.list.length >= \(maxItems)) return true;
      if (now - S.start > \(budgetMs)) return true;
      if (S.pages > 0 && now - S.last > \(stallMs)) return true;
      if (S.pages === 0 && now - S.start > \(firstPageMs)) return true;
      return false;
    })()
    """

    /// JS 字符串字面量（单引号，转义反斜杠 / 引号 / 换行）
    static func jsString(_ s: String) -> String {
        var out = "'"
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "'"
    }
}
