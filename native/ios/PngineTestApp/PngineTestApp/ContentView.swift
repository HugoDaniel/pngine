import SwiftUI
import PngineKit

// Test 4: Boids init + render (2430 bytes) - workgroups fixed to 32
let test4Bytecode = Data(base64Encoded: """
UE5HQgAAAAABAAAAAAAAAAAAAAB/AAAAigAAAHYJAAB7CQAAfQkAAAQAAQQBAgEAGCggAAAAAQHA
AIAAoAgAAwkBBAoAAQUzAAEGERIBEwAAGCABARk0MwEABxDAAP/+AQDAAP//EgAUAAEUAQAWA4gA
AAAZNDAAADUAMgEkMQEAAAAFAGJvaWRzCAAAAAAAGAAAABgAAACVAwAArQMAABcDAADEBgAAogEA
AGYIAAAsAAAAkggAABQAAACmCAAAAgAAAKgIAAACAAAACtcjvArXo7wK1yM8CtejvAAAAAAK16M8
CnN0cnVjdCBQYXJ0aWNsZSB7CiAgcG9zIDogdmVjMmYsCiAgdmVsIDogdmVjMmYsCn0KCnN0cnVj
dCBQYXJ0aWNsZXMgewogIHBhcnRpY2xlcyA6IGFycmF5PFBhcnRpY2xlPiwKfQoKQGJpbmRpbmco
MCkgQGdyb3VwKDApIHZhcjxzdG9yYWdlLCByZWFkX3dyaXRlPiBkYXRhIDogUGFydGljbGVzOwoK
Ly8gU2ltcGxlIGhhc2ggZm9yIHBzZXVkby1yYW5kb20gbnVtYmVycwpmbiBoYXNoKG46IHUzMikg
LT4gZjMyIHsKICB2YXIgeCA9IG47CiAgeCA9ICgoeCA+PiAxNnUpIF4geCkgKiAweDQ1ZDlmM2J1
OwogIHggPSAoKHggPj4gMTZ1KSBeIHgpICogMHg0NWQ5ZjNidTsKICB4ID0gKHggPj4gMTZ1KSBe
IHg7CiAgcmV0dXJuIGYzMih4KSAvIGYzMigweGZmZmZmZmZmdSk7Cn0KCkBjb21wdXRlIEB3b3Jr
Z3JvdXBfc2l6ZSg2NCkKZm4gbWFpbihAYnVpbHRpbihnbG9iYWxfaW52b2NhdGlvbl9pZCkgaWQg
OiB2ZWMzdSkgewogIGxldCBpID0gaWQueDsKICBsZXQgdG90YWwgPSBhcnJheUxlbmd0aCgmZGF0
YS5wYXJ0aWNsZXMpOwogIGlmIChpID49IHRvdGFsKSB7IHJldHVybjsgfQoKICBsZXQgdCA9IGYz
MihpKSAvIGYzMih0b3RhbCk7CiAgbGV0IGFuZ2xlID0gdCAqIDYuMjgzMTg1OyAgLy8gMiAqIDMu
MTQxNTkyNjUzNTg5NzkzCiAgbGV0IHJhZGl1cyA9IHNxcnQodCk7CgogIC8vIFNwaXJhbCBwYXR0
ZXJuIGZvciBpbml0aWFsIHBvc2l0aW9ucwogIGRhdGEucGFydGljbGVzW2ldLnBvcyA9IHZlYzJm
KGNvcyhhbmdsZSkgKiByYWRpdXMsIHNpbihhbmdsZSkgKiByYWRpdXMpOwoKICAvLyBSYW5kb20g
dmVsb2NpdGllcwogIGRhdGEucGFydGljbGVzW2ldLnZlbCA9IHZlYzJmKAogICAgKGhhc2goaSAq
IDJ1KSAtIDAuNSkgKiAwLjEsCiAgICAoaGFzaChpICogMnUgKyAxdSkgLSAwLjUpICogMC4xCiAg
KTsKfQoKc3RydWN0IFZlcnRleE91dHB1dCB7CiAgQGJ1aWx0aW4ocG9zaXRpb24pIHBvc2l0aW9u
IDogdmVjNGYsCiAgQGxvY2F0aW9uKDQpIGNvbG9yIDogdmVjNGYsCn0KCkB2ZXJ0ZXgKZm4gdmVy
dGV4TWFpbigKICBAbG9jYXRpb24oMCkgYV9wYXJ0aWNsZVBvcyA6IHZlYzJmLAogIEBsb2NhdGlv
bigxKSBhX3BhcnRpY2xlVmVsIDogdmVjMmYsCiAgQGxvY2F0aW9uKDIpIGFfcG9zIDogdmVjMmYK
KSAtPiBWZXJ0ZXhPdXRwdXQgewogIGxldCBhbmdsZSA9IC1hdGFuMihhX3BhcnRpY2xlVmVsLngs
IGFfcGFydGljbGVWZWwueSk7CiAgbGV0IHBvcyA9IHZlYzIoCiAgICAoYV9wb3MueCAqIGNvcyhh
bmdsZSkpIC0gKGFfcG9zLnkgKiBzaW4oYW5nbGUpKSwKICAgIChhX3Bvcy54ICogc2luKGFuZ2xl
KSkgKyAoYV9wb3MueSAqIGNvcyhhbmdsZSkpCiAgKTsKCiAgdmFyIG91dHB1dCA6IFZlcnRleE91
dHB1dDsKICBvdXRwdXQucG9zaXRpb24gPSB2ZWM0KHBvcyArIGFfcGFydGljbGVQb3MsIDAuMCwg
MS4wKTsKICBvdXRwdXQuY29sb3IgPSB2ZWM0KAogICAgMS4wIC0gc2luKGFuZ2xlICsgMS4wKSAt
IGFfcGFydGljbGVWZWwueSwKICAgIHBvcy54ICogMTAwLjAgLSBhX3BhcnRpY2xlVmVsLnkgKyAw
LjEsCiAgICBhX3BhcnRpY2xlVmVsLnggKyBjb3MoYW5nbGUgKyAwLjUpLAogICAgMS4wCiAgKTsK
ICByZXR1cm4gb3V0cHV0Owp9CgpAZnJhZ21lbnQKZm4gZnJhZ01haW4oQGxvY2F0aW9uKDQpIGNv
bG9yIDogdmVjNGYpIC0+IEBsb2NhdGlvbigwKSB2ZWM0ZiB7CiAgcmV0dXJuIGNvbG9yOwp9Cnsi
dmVydGV4Ijp7InNoYWRlciI6MSwiZW50cnlQb2ludCI6InZlcnRleE1haW4iLCJidWZmZXJzIjpb
eyJhcnJheVN0cmlkZSI6MTYsInN0ZXBNb2RlIjoiaW5zdGFuY2UiLCJhdHRyaWJ1dGVzIjpbeyJz
aGFkZXJMb2NhdGlvbiI6MCwib2Zmc2V0IjowLCJmb3JtYXQiOiJmbG9hdDMyeDIifSx7InNoYWRl
ckxvY2F0aW9uIjoxLCJvZmZzZXQiOjgsImZvcm1hdCI6ImZsb2F0MzJ4MiJ9XX0seyJhcnJheVN0
cmlkZSI6OCwic3RlcE1vZGUiOiJ2ZXJ0ZXgiLCJhdHRyaWJ1dGVzIjpbeyJzaGFkZXJMb2NhdGlv
biI6Miwib2Zmc2V0IjowLCJmb3JtYXQiOiJmbG9hdDMyeDIifV19XX0sImZyYWdtZW50Ijp7InNo
YWRlciI6MSwiZW50cnlQb2ludCI6ImZyYWdNYWluIn0sInByaW1pdGl2ZSI6eyJ0b3BvbG9neSI6
InRyaWFuZ2xlLWxpc3QifX17ImNvbXB1dGUiOnsic2hhZGVyIjowLCJlbnRyeVBvaW50IjoibWFp
biJ9fQMCAQcAAgMBAAABAAAAAAAAAAAAe317fQIBAAIAAAAA
""", options: .ignoreUnknownCharacters)!

// Test 4b: Simple instanced rendering (1315 bytes) - 4 triangles, no compute
let test4bBytecode = Data(base64Encoded: """
UE5HQgAAAAABAAAAAAAAAAAAAABjAAAAbQAAAB0FAAAgBQAAIgUAAAQAAgEAICggAAABAQEYKCABAAAIAAMzAAAEEMAA//4BAMAA//8SABQAABQBARYDBAAAGTQwAAAyACQxAQAAAAQAbWFpbgUAAAAAABgAAAAYAAAAIAAAADgAAADgAgAAGAMAAGwBAACEBAAAAgAAAJqZGb6amRm+mpkZPpqZGb4AAAAAmpkZPgAAAL8AAAC/AAAAPwAAAL8AAAC/AAAAPwAAAD8AAAA/CnN0cnVjdCBWZXJ0ZXhPdXRwdXQgewogIEBidWlsdGluKHBvc2l0aW9uKSBwb3NpdGlvbiA6IHZlYzRmLAogIEBsb2NhdGlvbigwKSBjb2xvciA6IHZlYzRmLAp9CgpAdmVydGV4CmZuIHZlcnRleE1haW4oCiAgQGxvY2F0aW9uKDApIGFfaW5zdGFuY2VQb3MgOiB2ZWMyZiwKICBAbG9jYXRpb24oMSkgYV92ZXJ0ZXhQb3MgOiB2ZWMyZiwKICBAYnVpbHRpbihpbnN0YW5jZV9pbmRleCkgaW5zdGFuY2VJZHggOiB1MzIKKSAtPiBWZXJ0ZXhPdXRwdXQgewogIHZhciBvdXRwdXQgOiBWZXJ0ZXhPdXRwdXQ7CiAgb3V0cHV0LnBvc2l0aW9uID0gdmVjNGYoYV92ZXJ0ZXhQb3MgKyBhX2luc3RhbmNlUG9zLCAwLjAsIDEuMCk7CgogIC8vIERpZmZlcmVudCBjb2xvciBwZXIgaW5zdGFuY2UKICBsZXQgY29sb3JzID0gYXJyYXk8dmVjNGYsIDQ+KAogICAgdmVjNGYoMS4wLCAwLjAsIDAuMCwgMS4wKSwgIC8vIHJlZAogICAgdmVjNGYoMC4wLCAxLjAsIDAuMCwgMS4wKSwgIC8vIGdyZWVuCiAgICB2ZWM0ZigwLjAsIDAuMCwgMS4wLCAxLjApLCAgLy8gYmx1ZQogICAgdmVjNGYoMS4wLCAxLjAsIDAuMCwgMS4wKSAgIC8vIHllbGxvdwogICk7CiAgb3V0cHV0LmNvbG9yID0gY29sb3JzW2luc3RhbmNlSWR4XTsKICByZXR1cm4gb3V0cHV0Owp9CgpAZnJhZ21lbnQKZm4gZnJhZ01haW4oQGxvY2F0aW9uKDApIGNvbG9yIDogdmVjNGYpIC0+IEBsb2NhdGlvbigwKSB2ZWM0ZiB7CiAgcmV0dXJuIGNvbG9yOwp9CnsidmVydGV4Ijp7InNoYWRlciI6MCwiZW50cnlQb2ludCI6InZlcnRleE1haW4iLCJidWZmZXJzIjpbeyJhcnJheVN0cmlkZSI6OCwic3RlcE1vZGUiOiJpbnN0YW5jZSIsImF0dHJpYnV0ZXMiOlt7InNoYWRlckxvY2F0aW9uIjowLCJvZmZzZXQiOjAsImZvcm1hdCI6ImZsb2F0MzJ4MiJ9XX0seyJhcnJheVN0cmlkZSI6OCwic3RlcE1vZGUiOiJ2ZXJ0ZXgiLCJhdHRyaWJ1dGVzIjpbeyJzaGFkZXJMb2NhdGlvbiI6MSwib2Zmc2V0IjowLCJmb3JtYXQiOiJmbG9hdDMyeDIifV19XX0sImZyYWdtZW50Ijp7InNoYWRlciI6MCwiZW50cnlQb2ludCI6ImZyYWdNYWluIn0sInByaW1pdGl2ZSI6eyJ0b3BvbG9neSI6InRyaWFuZ2xlLWxpc3QifX17fQECAAAAAA==
""")!

// Test 4d: Boids render with pre-initialized data (no compute) - 1219 bytes
let test4dBytecode = Data(base64Encoded: """
UE5HQgAAAAABAAAAAAAAAAAAAABjAAAAbQAAAL0EAADABAAAwgQAAAQAAgEAGCggAAABAQFAKCABAAAIAAMzAAAEEMAA//4BAMAA//8SABQAARQBABYDBAAAGTQwAAAyACQxAQAAAAQAbWFpbgUAAAAAAEAAAABAAAAAGAAAAFgAAAAqAgAAggIAAKIBAAAkBAAAAgAAAAAAAL8AAAA/AAAAAAAAAAAAAAA/AAAAPwAAAAAAAAAAAAAAvwAAAL8AAAAAAAAAAAAAAD8AAAC/AAAAAAAAAACamRm+mpkZvpqZGT6amRm+AAAAAJqZGT4Kc3RydWN0IFZlcnRleE91dHB1dCB7CiAgQGJ1aWx0aW4ocG9zaXRpb24pIHBvc2l0aW9uIDogdmVjNGYsCiAgQGxvY2F0aW9uKDApIGNvbG9yIDogdmVjNGYsCn0KCkB2ZXJ0ZXgKZm4gdmVydGV4TWFpbigKICBAbG9jYXRpb24oMCkgYV9wYXJ0aWNsZVBvcyA6IHZlYzJmLAogIEBsb2NhdGlvbigxKSBhX3BhcnRpY2xlVmVsIDogdmVjMmYsCiAgQGxvY2F0aW9uKDIpIGFfcG9zIDogdmVjMmYKKSAtPiBWZXJ0ZXhPdXRwdXQgewogIHZhciBvdXRwdXQgOiBWZXJ0ZXhPdXRwdXQ7CiAgb3V0cHV0LnBvc2l0aW9uID0gdmVjNChhX3BvcyArIGFfcGFydGljbGVQb3MsIDAuMCwgMS4wKTsKICBvdXRwdXQuY29sb3IgPSB2ZWM0KAogICAgYV9wYXJ0aWNsZVBvcy54ICogMC41ICsgMC41LAogICAgYV9wYXJ0aWNsZVBvcy55ICogMC41ICsgMC41LAogICAgMC41LAogICAgMS4wCiAgKTsKICByZXR1cm4gb3V0cHV0Owp9CgpAZnJhZ21lbnQKZm4gZnJhZ01haW4oQGxvY2F0aW9uKDApIGNvbG9yIDogdmVjNGYpIC0+IEBsb2NhdGlvbigwKSB2ZWM0ZiB7CiAgcmV0dXJuIGNvbG9yOwp9CnsidmVydGV4Ijp7InNoYWRlciI6MCwiZW50cnlQb2ludCI6InZlcnRleE1haW4iLCJidWZmZXJzIjpbeyJhcnJheVN0cmlkZSI6MTYsInN0ZXBNb2RlIjoiaW5zdGFuY2UiLCJhdHRyaWJ1dGVzIjpbeyJzaGFkZXJMb2NhdGlvbiI6MCwib2Zmc2V0IjowLCJmb3JtYXQiOiJmbG9hdDMyeDIifSx7InNoYWRlckxvY2F0aW9uIjoxLCJvZmZzZXQiOjgsImZvcm1hdCI6ImZsb2F0MzJ4MiJ9XX0seyJhcnJheVN0cmlkZSI6OCwic3RlcE1vZGUiOiJ2ZXJ0ZXgiLCJhdHRyaWJ1dGVzIjpbeyJzaGFkZXJMb2NhdGlvbiI6Miwib2Zmc2V0IjowLCJmb3JtYXQiOiJmbG9hdDMyeDIifV19XX0sImZyYWdtZW50Ijp7InNoYWRlciI6MCwiZW50cnlQb2ludCI6ImZyYWdNYWluIn0sInByaW1pdGl2ZSI6eyJ0b3BvbG9neSI6InRyaWFuZ2xlLWxpc3QifX17fQECAAAAAA==
""")!

// Test 4c: Instanced rendering using builtins only (1481 bytes) - no vertex buffers
let test4cBytecode = Data(base64Encoded: """
UE5HQgAAAAABAAAAAAAAAAAAAABNAAAAVwAAAMMFAADGBQAAyAUAAAQAAAgAATMAAAIQwAD//gEAwAD//xIAFgMEAAAZNDAAADIAJDEBAAAABABtYWluAwAAAAAAxgQAAMYEAACKAAAAUAUAAAIAAAAKc3RydWN0IFZlcnRleE91dHB1dCB7CiAgQGJ1aWx0aW4ocG9zaXRpb24pIHBvc2l0aW9uIDogdmVjNGYsCiAgQGxvY2F0aW9uKDApIGNvbG9yIDogdmVjNGYsCn0KCkB2ZXJ0ZXgKZm4gdmVydGV4TWFpbigKICBAYnVpbHRpbih2ZXJ0ZXhfaW5kZXgpIHZlcnRleElkeCA6IHUzMiwKICBAYnVpbHRpbihpbnN0YW5jZV9pbmRleCkgaW5zdGFuY2VJZHggOiB1MzIKKSAtPiBWZXJ0ZXhPdXRwdXQgewogIC8vIFRyaWFuZ2xlIHZlcnRpY2VzIChoYXJkY29kZWQpCiAgdmFyIHRyaWFuZ2xlVmVydGljZXMgPSBhcnJheTx2ZWMyZiwgMz4oCiAgICB2ZWMyZigtMC4xNSwgLTAuMTUpLAogICAgdmVjMmYoMC4xNSwgLTAuMTUpLAogICAgdmVjMmYoMC4wLCAwLjE1KQogICk7CgogIC8vIEluc3RhbmNlIHBvc2l0aW9ucyAoaGFyZGNvZGVkKQogIHZhciBpbnN0YW5jZVBvc2l0aW9ucyA9IGFycmF5PHZlYzJmLCA0PigKICAgIHZlYzJmKC0wLjUsIC0wLjUpLCAgLy8gaW5zdGFuY2UgMDogYm90dG9tLWxlZnQKICAgIHZlYzJmKDAuNSwgLTAuNSksICAgLy8gaW5zdGFuY2UgMTogYm90dG9tLXJpZ2h0CiAgICB2ZWMyZigtMC41LCAwLjUpLCAgIC8vIGluc3RhbmNlIDI6IHRvcC1sZWZ0CiAgICB2ZWMyZigwLjUsIDAuNSkgICAgIC8vIGluc3RhbmNlIDM6IHRvcC1yaWdodAogICk7CgogIGxldCB2ZXJ0ZXggPSB0cmlhbmdsZVZlcnRpY2VzW3ZlcnRleElkeF07CiAgbGV0IG9mZnNldCA9IGluc3RhbmNlUG9zaXRpb25zW2luc3RhbmNlSWR4XTsKCiAgdmFyIG91dHB1dCA6IFZlcnRleE91dHB1dDsKICBvdXRwdXQucG9zaXRpb24gPSB2ZWM0Zih2ZXJ0ZXggKyBvZmZzZXQsIDAuMCwgMS4wKTsKCiAgLy8gRGlmZmVyZW50IGNvbG9yIHBlciBpbnN0YW5jZQogIHZhciBjb2xvcnMgPSBhcnJheTx2ZWM0ZiwgND4oCiAgICB2ZWM0ZigxLjAsIDAuMCwgMC4wLCAxLjApLCAgLy8gcmVkCiAgICB2ZWM0ZigwLjAsIDEuMCwgMC4wLCAxLjApLCAgLy8gZ3JlZW4KICAgIHZlYzRmKDAuMCwgMC4wLCAxLjAsIDEuMCksICAvLyBibHVlCiAgICB2ZWM0ZigxLjAsIDEuMCwgMC4wLCAxLjApICAgLy8geWVsbG93CiAgKTsKICBvdXRwdXQuY29sb3IgPSBjb2xvcnNbaW5zdGFuY2VJZHhdOwogIHJldHVybiBvdXRwdXQ7Cn0KCkBmcmFnbWVudApmbiBmcmFnTWFpbihAbG9jYXRpb24oMCkgY29sb3IgOiB2ZWM0ZikgLT4gQGxvY2F0aW9uKDApIHZlYzRmIHsKICByZXR1cm4gY29sb3I7Cn0KeyJ2ZXJ0ZXgiOnsic2hhZGVyIjowLCJlbnRyeVBvaW50IjoidmVydGV4TWFpbiJ9LCJmcmFnbWVudCI6eyJzaGFkZXIiOjAsImVudHJ5UG9pbnQiOiJmcmFnTWFpbiJ9LCJwcmltaXRpdmUiOnsidG9wb2xvZ3kiOiJ0cmlhbmdsZS1saXN0In19e30BAAAAAAA=
""")!

// Test 4e: Boids with larger sprites (5x bigger, 0.05 units) + compute init (2066 bytes)
let test4eBytecode = Data(base64Encoded: """
UE5HQgAAAAABAAAAAAAAAAAAAAB/AAAAigAAAAoIAAAPCAAAEQgAAAQAAQQBAgEAGCggAAAAAQHAAIAAoAgAAwkBBAoAAQUzAAEGERIBEwAAGCABARk0MwEABxDAAP/+AQDAAP//EgAUAAEUAQAWA4gAAAAZNDAAADUAMgEkMQEAAAAFAGJvaWRzCAAAAAAAGAAAABgAAAAWAwAALgMAACoCAABYBQAAogEAAPoGAAAsAAAAJgcAABQAAAA6BwAAAgAAADwHAAACAAAAzcxMvc3MTL3NzEw9zcxMvQAAAADNzEw9CnN0cnVjdCBQYXJ0aWNsZSB7CiAgcG9zIDogdmVjMmYsCiAgdmVsIDogdmVjMmYsCn0KCnN0cnVjdCBQYXJ0aWNsZXMgewogIHBhcnRpY2xlcyA6IGFycmF5PFBhcnRpY2xlPiwKfQoKQGJpbmRpbmcoMCkgQGdyb3VwKDApIHZhcjxzdG9yYWdlLCByZWFkX3dyaXRlPiBkYXRhIDogUGFydGljbGVzOwoKZm4gaGFzaChuOiB1MzIpIC0+IGYzMiB7CiAgdmFyIHggPSBuOwogIHggPSAoKHggPj4gMTZ1KSBeIHgpICogMHg0NWQ5ZjNidTsKICB4ID0gKCh4ID4+IDE2dSkgXiB4KSAqIDB4NDVkOWYzYnU7CiAgeCA9ICh4ID4+IDE2dSkgXiB4OwogIHJldHVybiBmMzIoeCkgLyBmMzIoMHhmZmZmZmZmZnUpOwp9CgpAY29tcHV0ZSBAd29ya2dyb3VwX3NpemUoNjQpCmZuIG1haW4oQGJ1aWx0aW4oZ2xvYmFsX2ludm9jYXRpb25faWQpIGlkIDogdmVjM3UpIHsKICBsZXQgaSA9IGlkLng7CiAgbGV0IHRvdGFsID0gYXJyYXlMZW5ndGgoJmRhdGEucGFydGljbGVzKTsKICBpZiAoaSA+PSB0b3RhbCkgeyByZXR1cm47IH0KCiAgbGV0IHQgPSBmMzIoaSkgLyBmMzIodG90YWwpOwogIGxldCBhbmdsZSA9IHQgKiA2LjI4MzE4NTsKICBsZXQgcmFkaXVzID0gc3FydCh0KSAqIDAuODsKCiAgZGF0YS5wYXJ0aWNsZXNbaV0ucG9zID0gdmVjMmYoY29zKGFuZ2xlKSAqIHJhZGl1cywgc2luKGFuZ2xlKSAqIHJhZGl1cyk7CiAgZGF0YS5wYXJ0aWNsZXNbaV0udmVsID0gdmVjMmYoCiAgICAoaGFzaChpICogMnUpIC0gMC41KSAqIDAuMSwKICAgIChoYXNoKGkgKiAydSArIDF1KSAtIDAuNSkgKiAwLjEKICApOwp9CgpzdHJ1Y3QgVmVydGV4T3V0cHV0IHsKICBAYnVpbHRpbihwb3NpdGlvbikgcG9zaXRpb24gOiB2ZWM0ZiwKICBAbG9jYXRpb24oMCkgY29sb3IgOiB2ZWM0ZiwKfQoKQHZlcnRleApmbiB2ZXJ0ZXhNYWluKAogIEBsb2NhdGlvbigwKSBhX3BhcnRpY2xlUG9zIDogdmVjMmYsCiAgQGxvY2F0aW9uKDEpIGFfcGFydGljbGVWZWwgOiB2ZWMyZiwKICBAbG9jYXRpb24oMikgYV9wb3MgOiB2ZWMyZgopIC0+IFZlcnRleE91dHB1dCB7CiAgdmFyIG91dHB1dCA6IFZlcnRleE91dHB1dDsKICBvdXRwdXQucG9zaXRpb24gPSB2ZWM0KGFfcG9zICsgYV9wYXJ0aWNsZVBvcywgMC4wLCAxLjApOwogIG91dHB1dC5jb2xvciA9IHZlYzQoCiAgICBhX3BhcnRpY2xlUG9zLnggKiAwLjUgKyAwLjUsCiAgICBhX3BhcnRpY2xlUG9zLnkgKiAwLjUgKyAwLjUsCiAgICAwLjUsCiAgICAxLjAKICApOwogIHJldHVybiBvdXRwdXQ7Cn0KCkBmcmFnbWVudApmbiBmcmFnTWFpbihAbG9jYXRpb24oMCkgY29sb3IgOiB2ZWM0ZikgLT4gQGxvY2F0aW9uKDApIHZlYzRmIHsKICByZXR1cm4gY29sb3I7Cn0KeyJ2ZXJ0ZXgiOnsic2hhZGVyIjoxLCJlbnRyeVBvaW50IjoidmVydGV4TWFpbiIsImJ1ZmZlcnMiOlt7ImFycmF5U3RyaWRlIjoxNiwic3RlcE1vZGUiOiJpbnN0YW5jZSIsImF0dHJpYnV0ZXMiOlt7InNoYWRlckxvY2F0aW9uIjowLCJvZmZzZXQiOjAsImZvcm1hdCI6ImZsb2F0MzJ4MiJ9LHsic2hhZGVyTG9jYXRpb24iOjEsIm9mZnNldCI6OCwiZm9ybWF0IjoiZmxvYXQzMngyIn1dfSx7ImFycmF5U3RyaWRlIjo4LCJzdGVwTW9kZSI6InZlcnRleCIsImF0dHJpYnV0ZXMiOlt7InNoYWRlckxvY2F0aW9uIjoyLCJvZmZzZXQiOjAsImZvcm1hdCI6ImZsb2F0MzJ4MiJ9XX1dfSwiZnJhZ21lbnQiOnsic2hhZGVyIjoxLCJlbnRyeVBvaW50IjoiZnJhZ01haW4ifSwicHJpbWl0aXZlIjp7InRvcG9sb2d5IjoidHJpYW5nbGUtbGlzdCJ9fXsiY29tcHV0ZSI6eyJzaGFkZXIiOjAsImVudHJ5UG9pbnQiOiJtYWluIn19AwIBBwACAwEAAAEAAAAAAAAAAAB7fXt9AgEAAgAAAAA=
""")!

// Test 4f: No arrayLength - 64 particles with hard-coded limit (1820 bytes) - FIXED vertexMain typo
let test4fBytecode = Data(base64Encoded: """
UE5HQgAAAAABAAAAAAAAAAAAAAB8AAAAhwAAABQHAAAZBwAAGwcAAAQAAQQBAgEAGCggAAAAAQGEAKAIAAMJAQQKAAEFMwABBhESARMAABgBAQEZNDMBAAcQwAD//gEAwAD//xIAFAABFAEAFgNAAAAZNDAAADUAMgEkMQEAAAAFAGJvaWRzCAAAAAAAGAAAABgAAAAjAgAAOwIAACoCAABlBAAAogEAAAcGAAAsAAAAMwYAABQAAABHBgAAAgAAAEkGAAACAAAAzczMvc3MzL3NzMw9zczMvQAAAADNzMw9CnN0cnVjdCBQYXJ0aWNsZSB7CiAgcG9zIDogdmVjMmYsCiAgdmVsIDogdmVjMmYsCn0KCnN0cnVjdCBQYXJ0aWNsZXMgewogIHBhcnRpY2xlcyA6IGFycmF5PFBhcnRpY2xlPiwKfQoKQGJpbmRpbmcoMCkgQGdyb3VwKDApIHZhcjxzdG9yYWdlLCByZWFkX3dyaXRlPiBkYXRhIDogUGFydGljbGVzOwoKQGNvbXB1dGUgQHdvcmtncm91cF9zaXplKDY0KQpmbiBtYWluKEBidWlsdGluKGdsb2JhbF9pbnZvY2F0aW9uX2lkKSBpZCA6IHZlYzN1KSB7CiAgbGV0IGkgPSBpZC54OwogIC8vIEhBUkQtQ09ERUQgbGltaXQgaW5zdGVhZCBvZiBhcnJheUxlbmd0aAogIGlmIChpID49IDY0dSkgeyByZXR1cm47IH0KCiAgbGV0IHQgPSBmMzIoaSkgLyA2NC4wOwogIGxldCBhbmdsZSA9IHQgKiA2LjI4MzE4NTsKICBsZXQgcmFkaXVzID0gMC4zICsgdCAqIDAuNTsKCiAgZGF0YS5wYXJ0aWNsZXNbaV0ucG9zID0gdmVjMmYoY29zKGFuZ2xlKSAqIHJhZGl1cywgc2luKGFuZ2xlKSAqIHJhZGl1cyk7CiAgZGF0YS5wYXJ0aWNsZXNbaV0udmVsID0gdmVjMmYoMC4wLCAwLjApOwp9CgpzdHJ1Y3QgVmVydGV4T3V0cHV0IHsKICBAYnVpbHRpbihwb3NpdGlvbikgcG9zaXRpb24gOiB2ZWM0ZiwKICBAbG9jYXRpb24oMCkgY29sb3IgOiB2ZWM0ZiwKfQoKQHZlcnRleApmbiB2ZXJ0ZXhNYWluKAogIEBsb2NhdGlvbigwKSBhX3BhcnRpY2xlUG9zIDogdmVjMmYsCiAgQGxvY2F0aW9uKDEpIGFfcGFydGljbGVWZWwgOiB2ZWMyZiwKICBAbG9jYXRpb24oMikgYV9wb3MgOiB2ZWMyZgopIC0+IFZlcnRleE91dHB1dCB7CiAgdmFyIG91dHB1dCA6IFZlcnRleE91dHB1dDsKICBvdXRwdXQucG9zaXRpb24gPSB2ZWM0KGFfcG9zICsgYV9wYXJ0aWNsZVBvcywgMC4wLCAxLjApOwogIG91dHB1dC5jb2xvciA9IHZlYzQoCiAgICBhX3BhcnRpY2xlUG9zLnggKiAwLjUgKyAwLjUsCiAgICBhX3BhcnRpY2xlUG9zLnkgKiAwLjUgKyAwLjUsCiAgICAwLjUsCiAgICAxLjAKICApOwogIHJldHVybiBvdXRwdXQ7Cn0KCkBmcmFnbWVudApmbiBmcmFnTWFpbihAbG9jYXRpb24oMCkgY29sb3IgOiB2ZWM0ZikgLT4gQGxvY2F0aW9uKDApIHZlYzRmIHsKICByZXR1cm4gY29sb3I7Cn0KeyJ2ZXJ0ZXgiOnsic2hhZGVyIjoxLCJlbnRyeVBvaW50IjoidmVydGV4TWFpbiIsImJ1ZmZlcnMiOlt7ImFycmF5U3RyaWRlIjoxNiwic3RlcE1vZGUiOiJpbnN0YW5jZSIsImF0dHJpYnV0ZXMiOlt7InNoYWRlckxvY2F0aW9uIjowLCJvZmZzZXQiOjAsImZvcm1hdCI6ImZsb2F0MzJ4MiJ9LHsic2hhZGVyTG9jYXRpb24iOjEsIm9mZnNldCI6OCwiZm9ybWF0IjoiZmxvYXQzMngyIn1dfSx7ImFycmF5U3RyaWRlIjo4LCJzdGVwTW9kZSI6InZlcnRleCIsImF0dHJpYnV0ZXMiOlt7InNoYWRlckxvY2F0aW9uIjoyLCJvZmZzZXQiOjAsImZvcm1hdCI6ImZsb2F0MzJ4MiJ9XX1dfSwiZnJhZ21lbnQiOnsic2hhZGVyIjoxLCJlbnRyeVBvaW50IjoiZnJhZ01haW4ifSwicHJpbWl0aXZlIjp7InRvcG9sb2d5IjoidHJpYW5nbGUtbGlzdCJ9fXsiY29tcHV0ZSI6eyJzaGFkZXIiOjAsImVudHJ5UG9pbnQiOiJtYWluIn19AwIBBwACAwEAAAEAAAAAAAAAAAB7fXt9AgEAAgAAAAA=
""")!

// Currently active test
let activeBytecode = test4fBytecode
let activeTestName = "Test 4f: No arrayLength (hard-coded 64 particles)"

struct ContentView: View {
    @State private var status = "Tap to initialize"
    @State private var isInitialized = false
    @State private var version = ""
    @State private var bytecodeStatus = ""
    @State private var computeCounters = ""
    @State private var backgroundBehavior: PngineBackgroundBehavior = .pauseAndRestore

    var body: some View {
        VStack(spacing: 16) {
            Text("PNGine iOS Test")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(activeTestName)
                .font(.headline)
                .foregroundColor(.blue)

            Text(status)
                .font(.body)
                .foregroundColor(isInitialized ? .green : .orange)

            if !version.isEmpty {
                Text("Version: \(version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(bytecodeStatus)
                .font(.caption)
                .foregroundColor(.secondary)

            if !computeCounters.isEmpty {
                Text(computeCounters)
                    .font(.caption)
                    .foregroundColor(.purple)
            }

            // Background behavior picker
            HStack {
                Text("Background:")
                    .font(.caption)
                Picker("Background Behavior", selection: $backgroundBehavior) {
                    Text("Pause & Restore").tag(PngineBackgroundBehavior.pauseAndRestore)
                    Text("Pause").tag(PngineBackgroundBehavior.pause)
                    Text("Stop").tag(PngineBackgroundBehavior.stop)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)

            if isInitialized {
                PngineView(bytecode: activeBytecode)
                    .backgroundBehavior(backgroundBehavior)
                    .frame(width: 300, height: 300)
                    .background(Color.black)
                    .cornerRadius(12)
            } else {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 300, height: 300)
                    .cornerRadius(12)
            }

            Button(action: testInit) {
                Label("Test Initialize", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Send app to background to test lifecycle")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .onAppear {
            bytecodeStatus = "Bytecode: \(activeBytecode.count) bytes"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                testInit()
            }
        }
    }

    func testInit() {
        status = "Testing PngineKit..."
        version = pngineVersion()
        let result = pngine_init()

        if result == 0 {
            status = "PNGine initialized!"
            isInitialized = true

            // Check compute counters after a short delay (to allow first frame to render)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                checkComputeCounters()
            }
        } else {
            let error = pngineLastError() ?? "Unknown error"
            status = "Init failed: \(error)"
            isInitialized = false
        }
    }

    func checkComputeCounters() {
        let counters = pngine_debug_compute_counters()
        // Format: [passes:8][pipelines:8][bindgroups:8][dispatches:8]
        let passes = (counters >> 24) & 0xFF
        let pipelines = (counters >> 16) & 0xFF
        let bindgroups = (counters >> 8) & 0xFF
        let dispatches = counters & 0xFF

        let renderCounters = pngine_debug_render_counters()
        // Format: [render_passes:16][draws:16]
        let renderPasses = (renderCounters >> 16) & 0xFFFF
        let draws = renderCounters & 0xFFFF

        let bufferIds = pngine_debug_buffer_ids()
        // Format: [last_vertex_buffer_id:16][last_storage_bind_buffer_id:16]
        let vertexBufferId = (bufferIds >> 16) & 0xFFFF
        let storageBufferId = bufferIds & 0xFFFF

        let firstBufferIds = pngine_debug_first_buffer_ids()
        // Format: [first_vertex_buffer_id:16][first_storage_bind_buffer_id:16]
        let firstVertexBufferId = (firstBufferIds >> 16) & 0xFFFF
        let firstStorageBufferId = firstBufferIds & 0xFFFF

        let buf0Size = pngine_debug_buffer_0_size()
        let dispatchX = pngine_debug_dispatch_x()

        let drawInfo = pngine_debug_draw_info()
        // Format: [vertex_count:16][instance_count:16]
        let vertexCount = (drawInfo >> 16) & 0xFFFF
        let instanceCount = drawInfo & 0xFFFF

        computeCounters = "Compute: p=\(passes) bg=\(bindgroups) d=\(dispatches) x=\(dispatchX)\nRender: p=\(renderPasses) d=\(draws) v=\(vertexCount) i=\(instanceCount)\nFirst: vb=\(firstVertexBufferId) sb=\(firstStorageBufferId) | buf0=\(buf0Size)B"
    }
}

#Preview {
    ContentView()
}
