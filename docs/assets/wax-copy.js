// Copy-to-clipboard button for Wax code blocks.
//
// The wax-highlight preprocessor emits <pre class="wax-highlight"> with no
// inner <code> (to keep mdbook's highlight.js from re-tokenizing and wiping
// our spans). mdbook only adds its own copy button to `pre code`, so these
// blocks would otherwise have none. We add one here, reusing mdbook's
// `clip-button` styling (icon, hover reveal, tooltip).
//
// mdbook wires copying through a single document-delegated
// `ClipboardJS('.clip-button')` whose text callback reads `pre > code` — null
// for us. So our click handler calls stopPropagation(): the event never
// bubbles to that delegated listener, and we copy the block ourselves.

'use strict';

(function () {
    function ready(fn) {
        if (document.readyState !== 'loading') {
            fn();
        } else {
            document.addEventListener('DOMContentLoaded', fn);
        }
    }

    ready(function () {
        document.querySelectorAll('pre.wax-highlight').forEach(function (pre) {
            // Capture the code before inserting the button, so the button's
            // own text can never leak into what we copy.
            const code = pre.textContent;

            let buttons = pre.querySelector('.buttons');
            if (!buttons) {
                buttons = document.createElement('div');
                buttons.className = 'buttons';
                pre.insertBefore(buttons, pre.firstChild);
            }

            const button = document.createElement('button');
            button.className = 'clip-button';
            button.title = 'Copy to clipboard';
            button.setAttribute('aria-label', button.title);
            // The clipboard icon comes from mdbook's `.clip-button::before`; the
            // <i> only holds the "Copied!" tooltip text. The tooltip floats
            // above the button and, because the outer <pre> does not clip
            // (the scroll lives on the inner .wax-code), it renders in full.
            button.innerHTML = '<i class="tooltiptext"></i>';
            buttons.insertBefore(button, buttons.firstChild);

            button.addEventListener('click', function (e) {
                // Keep mdbook's delegated ClipboardJS handler from also firing.
                e.stopPropagation();
                navigator.clipboard.writeText(code).then(function () {
                    const tip = button.querySelector('.tooltiptext');
                    if (!tip) return;
                    tip.innerText = 'Copied!';
                    button.classList.add('tooltipped');
                    setTimeout(function () {
                        button.classList.remove('tooltipped');
                        tip.innerText = '';
                    }, 1200);
                });
            });
        });
    });
})();
