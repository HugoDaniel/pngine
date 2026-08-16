import { pngine, play } from "pngine"
import shaderUrl from "./shader.png"

const canvas = document.getElementById("canvas")
const p = await pngine(shaderUrl, { canvas })
play(p)
