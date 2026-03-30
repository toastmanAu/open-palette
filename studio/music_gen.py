"""MusicGen backend — text-to-music generation via Meta's audiocraft."""

import asyncio
import os
from pathlib import Path

# Force CPU to avoid GPU contention with ComfyUI
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")


class MusicGenEngine:
    name = "musicgen"

    MODELS = [
        {"id": "facebook/musicgen-small", "name": "MusicGen Small (300M)", "size": "small", "params": "300M"},
        {"id": "facebook/musicgen-medium", "name": "MusicGen Medium (1.5B)", "size": "medium", "params": "1.5B"},
    ]

    def __init__(self, config: dict = None):
        self._model = None
        self._model_id = None
        config = config or {}
        self.default_model = config.get("model", "facebook/musicgen-small")

    def available(self) -> bool:
        try:
            import audiocraft  # noqa: F401
            return True
        except ImportError:
            return False

    def models(self) -> list[dict]:
        return [dict(m) for m in self.MODELS]

    def _get_model(self, model_id: str = None):
        model_id = model_id or self.default_model
        if self._model is None or self._model_id != model_id:
            from audiocraft.models import MusicGen
            self._model = MusicGen.get_pretrained(model_id)
            self._model_id = model_id
        return self._model

    async def generate(self, prompt: str, output_path: str,
                       duration: float = 15.0, model_id: str = None) -> dict:
        """Generate music from text prompt. Returns metadata."""
        loop = asyncio.get_event_loop()

        def _do():
            import torch
            import soundfile as sf

            model = self._get_model(model_id)
            model.set_generation_params(duration=min(duration, 30.0))

            with torch.no_grad():
                wav = model.generate([prompt])

            # wav shape: [batch, channels, samples]
            audio = wav[0].cpu().numpy()
            if audio.ndim == 2:
                audio = audio.T  # channels last for soundfile
            elif audio.ndim == 1:
                pass  # mono

            sample_rate = model.sample_rate
            sf.write(output_path, audio, sample_rate)

            actual_duration = len(audio) / sample_rate if audio.ndim == 1 else audio.shape[0] / sample_rate

            return {
                "duration": round(actual_duration, 2),
                "sample_rate": sample_rate,
                "file_size": os.path.getsize(output_path),
                "model": model_id or self.default_model,
            }

        return await loop.run_in_executor(None, _do)
