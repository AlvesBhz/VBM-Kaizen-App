/* =====================================================================
   Gerador das conexões (linhas) do DER_VBM_Kaizen.html
   ---------------------------------------------------------------------
   Recalcula os <path class="rel"> do SVG a partir da geometria das
   tabelas. Rode assim e cole a saída no lugar do bloco de <path> do HTML:

       node compute_lines.js > paths.txt

   A stderr sai o tamanho do canvas (útil se alguma tabela for movida).

   Mantenha este arquivo em sincronia com o HTML: as alturas em `rects`
   têm de bater com os style="height:..." de cada .entity, senão as
   linhas saem ancoradas no lugar errado.
   ===================================================================== */

const rects = {
  IDIOMA:            {x:350,  y:0,    w:260, h:230},
  MDM:               {x:700,  y:0,    w:260, h:384},
  APROVADOR:         {x:1050, y:0,    w:260, h:164},
  ADMIN:             {x:1400, y:0,    w:260, h:164},
  TIPO_USUARIO:      {x:1750, y:0,    w:260, h:142},
  CATEGORIA:         {x:0,    y:428,  w:260, h:230},
  REPLICACAO:        {x:350,  y:428,  w:260, h:230},
  DESPERDICIO:       {x:700,  y:428,  w:260, h:230},
  MOEDA:             {x:1050, y:428,  w:260, h:208},
  TIPO_RESULTADO:    {x:1400, y:428,  w:260, h:186},
  STATUS:            {x:1750, y:428,  w:260, h:230},
  TIPO_KAIZEN:       {x:2100, y:428,  w:260, h:208},
  RESULTADOS:        {x:525,  y:724,  w:260, h:252},
  PVC:               {x:475,  y:1072, w:320, h:692},
  LOG:               {x:885,  y:1072, w:300, h:164},
  LOG_DETALHE:       {x:1235, y:1072, w:300, h:164},
  MEMBROS:           {x:350,  y:1824, w:260, h:120},
  RESULTADO_KAIZEN:  {x:700,  y:1824, w:260, h:120},
  KAIZEN_HIERARQUIA: {x:1050, y:1824, w:260, h:142},
  KZDESP:            {x:1400, y:1824, w:260, h:120},
};

// métricas do CSS: 44px cabeçalho + 6px padding do corpo + 22px por linha
const HEAD_H = 44, BODY_PAD = 6, ROW_H = 22, CORNER_R = 10;
function rowY(r, idx){ return r.y + HEAD_H + BODY_PAD + idx*ROW_H + ROW_H/2; }
function centerX(r){ return r.x + r.w/2; }

function rowAnchors(rFrom, fkRow, rTo, pkRow) {
  const fromRight = centerX(rTo) >= centerX(rFrom);
  const toLeft = fromRight;
  const p1 = {x: fromRight ? rFrom.x+rFrom.w : rFrom.x, y: rowY(rFrom, fkRow)};
  const p2 = {x: toLeft   ? rTo.x            : rTo.x+rTo.w, y: rowY(rTo, pkRow)};
  return {p1, p2};
}

// um segmento horizontal (y1===y2) ou vertical (x1===x2) cruza o RETÂNGULO r?
// (toque exato na borda não conta — só cruzar o interior)
function segRectHit(x1,y1,x2,y2,r){
  const rx0=r.x, rx1=r.x+r.w, ry0=r.y, ry1=r.y+r.h;
  if(y1===y2){
    if(y1<=ry0 || y1>=ry1) return false;
    const xlo=Math.min(x1,x2), xhi=Math.max(x1,x2);
    return xhi>rx0 && xlo<rx1;
  }
  if(x1<=rx0 || x1>=rx1) return false;
  const ylo=Math.min(y1,y2), yhi=Math.max(y1,y2);
  return yhi>ry0 && ylo<ry1;
}

// o cotovelo (2 trechos retos + 1 vertical no xMid) cruza alguma tabela
// que NÃO seja a origem/destino desta conexão?
function pathCollides(xMid, p1, p2, rFrom, rTo, allRects){
  for(const key in allRects){
    const r = allRects[key];
    if(r===rFrom || r===rTo) continue;
    if(segRectHit(p1.x,p1.y, xMid,p1.y, r)) return true;
    if(segRectHit(xMid,p2.y, p2.x,p2.y, r)) return true;
    if(segRectHit(xMid,p1.y, xMid,p2.y, r)) return true;
  }
  return false;
}

// acha o xMid mais próximo do natural que não atravessa nenhuma tabela
// de terceiros — sem isso, quando a origem e o destino ficam em colunas
// que se sobrepõem (ex.: PVC × uma tabela de domínio), o cotovelo natural
// pode passar por trás de uma tabela que não tem nada a ver com essa
// ligação, e o trecho visível entre duas tabelas "hidden" parece flutuar
// sem conexão com nada
function findSafeXMid(p1, p2, rFrom, rTo, allRects){
  const natural = (p1.x + p2.x) / 2;
  if(!pathCollides(natural, p1, p2, rFrom, rTo, allRects)) return natural;
  const STEP = 5, MAX = 1400;
  for(let d=STEP; d<=MAX; d+=STEP){
    if(!pathCollides(natural-d, p1, p2, rFrom, rTo, allRects)) return natural-d;
    if(!pathCollides(natural+d, p1, p2, rFrom, rTo, allRects)) return natural+d;
  }
  return natural; // não achou (não deveria acontecer no nosso layout) — usa o natural mesmo
}

function elbowPath(p1, p2, xMid, r) {
  r = r || CORNER_R;
  if (Math.abs(p1.y - p2.y) < 0.5) return `M${p1.x},${p1.y} L${p2.x},${p2.y}`;
  const dxSign = Math.sign(xMid - p1.x) || 1;
  const dySign = Math.sign(p2.y - p1.y) || 1;
  const rr = Math.max(2, Math.min(r, Math.abs(xMid-p1.x), Math.abs(p2.x-xMid), Math.abs(p2.y-p1.y)/2));
  const a = {x: xMid - dxSign*rr, y: p1.y};
  const b = {x: xMid,             y: p1.y + dySign*rr};
  const c = {x: xMid,             y: p2.y - dySign*rr};
  const d = {x: xMid + dxSign*rr, y: p2.y};
  return `M${p1.x},${p1.y} L${a.x},${a.y} Q${xMid},${p1.y} ${b.x},${b.y} L${c.x},${c.y} Q${xMid},${p2.y} ${d.x},${d.y} L${p2.x},${p2.y}`;
}

const LINE_COLOR = '#b7bec6';

// [tabelaOrigem, tabelaDestino, linhaDaFK, (opcional) linhaDaPKnoDestino]
const rels = [
  ['CATEGORIA','IDIOMA',1],
  ['STATUS','IDIOMA',1],
  ['STATUS','MDM',6],
  ['REPLICACAO','IDIOMA',1],
  ['DESPERDICIO','IDIOMA',1],
  ['TIPO_RESULTADO','IDIOMA',1],
  ['RESULTADOS','IDIOMA',1],
  ['RESULTADOS','TIPO_RESULTADO',3],
  ['APROVADOR','MDM',3],
  ['APROVADOR','MDM',1,1],
  ['ADMIN','MDM',3],
  ['ADMIN','MDM',1,1],
  ['TIPO_USUARIO','MDM',2],
  ['MDM','TIPO_USUARIO',2],
  ['IDIOMA','MDM',6],
  ['CATEGORIA','MDM',6],
  ['REPLICACAO','MDM',6],
  ['DESPERDICIO','MDM',6],
  ['MOEDA','MDM',5],
  ['TIPO_RESULTADO','MDM',4],
  ['RESULTADOS','MDM',7],
  ['PVC','MDM',1],
  ['PVC','MDM',2],
  ['PVC','MDM',23],
  ['PVC','STATUS',8],
  ['PVC','CATEGORIA',4],
  ['PVC','REPLICACAO',5],
  ['PVC','APROVADOR',9],
  // ['PVC','DESPERDICIO',15] removida: ID_DESPERDICIO virou DS_COMPARA_META
  // (VARCHAR(300) de texto livre), entao nao ha mais relacao com KZN_DESPERDICIO.
  ['PVC','MOEDA',18],
  ['PVC','TIPO_KAIZEN',26],
  ['TIPO_KAIZEN','IDIOMA',1],
  ['TIPO_KAIZEN','MDM',5],
  ['LOG','PVC',1],
  ['LOG','MDM',4],
  ['LOG_DETALHE','LOG',1],
  ['MEMBROS','PVC',0],
  ['MEMBROS','MDM',1],
  ['RESULTADO_KAIZEN','PVC',0],
  ['RESULTADO_KAIZEN','RESULTADOS',1],
  ['KAIZEN_HIERARQUIA','PVC',0],      // ID_KAIZEN        -> PVC.ID_KAIZEN (linha 0)
  ['KAIZEN_HIERARQUIA','PVC',1,2],    // ID_USUARIO_LIDER -> PVC.ID_USUARIO_LIDER (linha 2)
  ['KZDESP','PVC',0],
  ['KZDESP','DESPERDICIO',1],
];

// relações sem FK de banco (PK composta no destino) — desenhadas tracejadas
const softRels = new Set([
  'PVC>STATUS','PVC>CATEGORIA','PVC>REPLICACAO','PVC>TIPO_KAIZEN',
  'RESULTADO_KAIZEN>RESULTADOS',
  'KZDESP>DESPERDICIO',
  'MEMBROS>MDM',
]);

// destino de cada ligação aponta pra linha 0 (1ª coluna) por padrão — em
// todas as tabelas a PK (ou a 1ª coluna da PK composta) é a 1ª coluna
// física, então nenhuma tabela precisa de override aqui.
const toRowOverride = {};

let out = [];
rels.forEach(([fromKey,toKey,fkRow,toRowExplicit])=>{
  const rFrom = rects[fromKey], rTo = rects[toKey];
  const toRow = toRowExplicit !== undefined ? toRowExplicit : (toRowOverride[toKey] || 0);
  const {p1,p2} = rowAnchors(rFrom, fkRow, rTo, toRow);
  const xMid = findSafeXMid(p1, p2, rFrom, rTo, rects);
  const d = elbowPath(p1, p2, xMid);
  const soft = softRels.has(`${fromKey}>${toKey}`) ? ' soft' : '';
  const pkRowAttr = toRow ? ` data-pk-row="${toRow}"` : '';
  out.push(`<path class="rel${soft}" d="${d}" marker-end="url(#arrow-key)" data-from="e_${fromKey}" data-to="e_${toKey}" data-fk-row="${fkRow}"${pkRowAttr}/>`);
});

console.log(out.join('\n'));
let maxX=0, maxY=0;
Object.values(rects).forEach(r=>{ maxX=Math.max(maxX,r.x+r.w); maxY=Math.max(maxY,r.y+r.h); });
console.error(`CANVAS ${maxX} x ${maxY}`);
