"""Google Gemini / Imagen image generation backend."""

import base64
import json
import os

import aiohttp

from backends.base import BaseBackend

# Imagen models use the predict endpoint, Gemini models use generateContent
IMAGEN_MODELS = {"imagen-4.0-generate-001", "imagen-4.0-ultra-generate-001", "imagen-4.0-fast-generate-001"}


class GeminiBackend(BaseBackend):
    async def generate(self, params, output_path, on_progress):
        api_key = self.api_key or os.environ.get("GEMINI_API_KEY", "")
        if not api_key:
            raise RuntimeError("Gemini API key not configured (set GEMINI_API_KEY or config)")

        model = params.get("model", "gemini-2.5-flash-image")
        prompt = params["prompt"]

        if model in IMAGEN_MODELS:
            await self._generate_imagen(api_key, model, params, output_path, on_progress)
        else:
            await self._generate_gemini(api_key, model, params, output_path, on_progress)

    async def _generate_gemini(self, api_key, model, params, output_path, on_progress):
        """Gemini multimodal models (Nano Banana etc) — generateContent with IMAGE modality."""
        prompt = params["prompt"]
        await on_progress(10, f"Sending to {model}...")

        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"

        parts = []
        ref_images = params.get("reference_images", [])
        for ref_path in ref_images[:4]:
            with open(ref_path, "rb") as f:
                img_data = base64.b64encode(f.read()).decode()
            parts.append({
                "inline_data": {"mime_type": "image/png", "data": img_data}
            })

        if ref_images:
            parts.append({"text": f"Generate an image based on these reference images: {prompt}"})
        else:
            parts.append({"text": f"Generate an image: {prompt}"})

        payload = {
            "contents": [{"parts": parts}],
            "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]},
        }

        await on_progress(30, "Waiting for response...")

        async with aiohttp.ClientSession() as session:
            async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=120)) as resp:
                if resp.status != 200:
                    text = await resp.text()
                    raise RuntimeError(f"Gemini error: {text[:500]}")
                result = await resp.json()

        await on_progress(80, "Processing response...")

        for candidate in result.get("candidates", []):
            for part in candidate.get("content", {}).get("parts", []):
                if "inlineData" in part:
                    img_b64 = part["inlineData"]["data"]
                    with open(output_path, "wb") as f:
                        f.write(base64.b64decode(img_b64))
                    await on_progress(100, "Done")
                    return

        raise RuntimeError("No image in Gemini response — model may have refused the prompt")

    async def _generate_imagen(self, api_key, model, params, output_path, on_progress):
        """Imagen models — dedicated image generation endpoint."""
        prompt = params["prompt"]
        await on_progress(10, f"Sending to {model}...")

        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:predict?key={api_key}"

        payload = {
            "instances": [{"prompt": prompt}],
            "parameters": {
                "sampleCount": 1,
            },
        }

        await on_progress(30, "Generating...")

        async with aiohttp.ClientSession() as session:
            async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=120)) as resp:
                if resp.status != 200:
                    text = await resp.text()
                    raise RuntimeError(f"Imagen error: {text[:500]}")
                result = await resp.json()

        await on_progress(80, "Processing...")

        predictions = result.get("predictions", [])
        if predictions and "bytesBase64Encoded" in predictions[0]:
            img_b64 = predictions[0]["bytesBase64Encoded"]
            with open(output_path, "wb") as f:
                f.write(base64.b64decode(img_b64))
            await on_progress(100, "Done")
            return

        raise RuntimeError("No image in Imagen response")
