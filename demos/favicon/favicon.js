import { pngine, draw } from 'pngine';

async function main() {
    const canvas = document.getElementById('canvas');
    const favicon = document.getElementById('favicon');

    // Initialize PNGine with the compiled shader
    const p = await pngine('favicon.png', {
        canvas,
        devicePixelRatio: 1
    });

    console.log('PNGine initialized:', p);

    const startTime = performance.now();
    let lastUpdate = 0;

    function loop() {
        const now = performance.now();
        const time = (now - startTime) / 1000;

        // Render frame
        draw(p, { time });

        // Update favicon (throttled to 10fps)
        if (now - lastUpdate > 100) {
            favicon.href = canvas.toDataURL('image/png');
            lastUpdate = now;
        }

        requestAnimationFrame(loop);
    }

    loop();
}

main().catch(err => {
    console.error(err);
    document.body.innerHTML += `<pre style="color:red">${err.stack}</pre>`;
});
