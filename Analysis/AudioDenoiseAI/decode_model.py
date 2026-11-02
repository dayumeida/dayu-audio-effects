"""Read-only decoding of the installed model resource; never changes licensing."""
from pathlib import Path
import hashlib
root=Path(__file__).parent
resource=Path('/Library/Audio/Plug-Ins/Components/AudioDenoise AI.component/Contents/Resources/left.png')
source=resource.read_bytes();key=b'denoise_plugin#@_audio'
model=bytes(v^key[i%len(key)] for i,v in enumerate(source))
assert hashlib.sha256(model).hexdigest()=='c5b58a4c91a250a9829cf8c4aab6e81eaf1092d0a09048117a98dc8f8e9dcc15'
(root/'model.onnx').write_bytes(model)
print(len(model),hashlib.sha256(model).hexdigest())
