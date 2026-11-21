package cc.polv.lingua.srs

import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The Markdown editor's WebView only takes native focus from a touch
        // on it, and without native focus a JavaScript focus() opens no
        // keyboard. After a tap on the editor's placeholder (or Edit), the
        // app asks for focus here instead.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lingua/markdown_editor")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "focus" -> {
                        val title = call.argument<String>("title")
                        val script = call.argument<String>("script")
                        val webView = title?.let { findWebView(window.decorView, it) }
                        if (webView == null) {
                            result.success(false)
                        } else {
                            webView.requestFocus()
                            if (script != null) webView.evaluateJavascript(script, null)
                            // After the page has focused the textarea, so the
                            // keyboard opens for it.
                            webView.post {
                                val imm = getSystemService(Context.INPUT_METHOD_SERVICE)
                                    as InputMethodManager
                                imm.showSoftInput(webView, InputMethodManager.SHOW_IMPLICIT)
                            }
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** The WebView showing a page titled [title]: one editor's own page. */
    private fun findWebView(view: View, title: String): WebView? {
        if (view is WebView) return if (view.title == title) view else null
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findWebView(view.getChildAt(i), title)?.let { return it }
            }
        }
        return null
    }
}
