function rnd() {
  return (Math.random() * 2.0 - 1.0).toFixed(4);
}

for (let i = 0; i < 7; ++i) {
  console.log(`vec3f(${rnd()}, ${rnd()}, ${rnd()}),`);
}
