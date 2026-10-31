"""Converts InsightFace's MobileFaceNet (w600k_mbf.onnx, from buffalo_s.zip) to CoreML.

    curl -LO https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_s.zip
    unzip buffalo_s.zip w600k_mbf.onnx
    uv venv -p 3.12 .venv && VIRTUAL_ENV=.venv uv pip install "torch==2.7.0" "torchvision==0.22.0" onnx onnx2torch coremltools numpy pillow
    .venv/bin/python tools/convert_model.py w600k_mbf.onnx models/FaceEmbedder.mlpackage

The weights are licensed by InsightFace for non-commercial research use only; they are not in this repo.
"""
import sys, torch, onnx, numpy as np, coremltools as ct
from onnx2torch import convert
src, dst = sys.argv[1], sys.argv[2]
model = convert(onnx.load(src)).eval()
x = torch.randn(1, 3, 112, 112)
traced = torch.jit.trace(model, x)
ml = ct.convert(
    traced,
    inputs=[ct.ImageType(name="face", shape=(1, 3, 112, 112), color_layout=ct.colorlayout.RGB,
                         scale=1/127.5, bias=[-1.0, -1.0, -1.0])],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS13,
    compute_precision=ct.precision.FLOAT16,
)
ml.short_description = "MobileFaceNet (InsightFace w600k_mbf) face embedding, 112x112 aligned RGB in, 512-d out"
ml.save(dst)
# parity check vs torch on a random image
img = (np.random.rand(112,112,3)*255).astype(np.uint8)
from PIL import Image
t = torch.from_numpy(((img.astype(np.float32)-127.5)/127.5).transpose(2,0,1)[None])
ref = model(t).detach().numpy()[0]
out = ml.predict({"face": Image.fromarray(img)})["embedding"][0]
cos = float(np.dot(ref,out)/np.linalg.norm(ref)/np.linalg.norm(out))
print("cosine torch vs coreml:", cos)
