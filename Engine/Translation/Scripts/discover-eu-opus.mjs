import fs from 'node:fs';
const rows = [
['bg','tc-big-en-bg','tc-big-bg-en'],['cs','en-cs','tc-big-ces_slk-en'],
['da','tc-big-en-gmq','tc-big-gmq-en','>>dan<<'],['de','en-de','de-en'],
['el','tc-big-en-el','tc-big-el-en'],['es','tc-big-en-es','tc-big-cat_oci_spa-en'],
['et','tc-big-en-et','tc-big-et-en'],['fr','tc-big-en-fr','tc-big-fr-en'],
['ga','en-ga','ga-en'],['hr','en-zls','tc-big-zls-en','>>hrv<<'],
['hu','tc-big-en-hu','tc-big-hu-en'],['it','tc-big-en-it','tc-big-it-en'],
['lt','tc-big-en-lt','tc-big-lt-en'],['lv','tc-big-en-lv','tc-big-lv-en'],
['mt','en-mt','mt-en'],['nl','en-nl','nl-en'],['pl','en-zlw','tc-big-zlw-en','>>pol<<'],
['pt','tc-big-en-pt','ROMANCE-en','>>por<<'],['ro','tc-big-en-ro','ROMANCE-en'],
['sk','en-sk','tc-big-ces_slk-en'],['sl','en-zls','tc-big-zls-en','>>slv<<'],
['sv','tc-big-en-gmq','tc-big-gmq-en','>>swe<<'],['uk','tc-big-en-zle','tc-big-zle-en','>>ukr<<'],
['ca','tc-big-en-cat_oci_spa','tc-big-cat_oci_spa-en','>>cat<<'],['nb','tc-big-en-gmq','tc-big-gmq-en','>>nob<<'],
['is','tc-big-en-gmq','tc-big-gmq-en','>>isl<<'],['sr','en-zls','tc-big-zls-en','>>srp_Cyrl<<'],
['bs','en-zls','tc-big-zls-en','>>bos_Latn<<'],['mk','en-zls','tc-big-zls-en','>>mkd<<'],
['be','tc-big-en-zle','tc-big-zle-en','>>bel<<'],['ar','tc-big-en-ar','tc-big-ar-en','>>ara<<']];
const samples = {bg:'Ще изпратя документите утре.',cs:'Pošlu dokumenty zítra.',da:'Jeg sender dokumenterne i morgen.',de:'Ich schicke die Dokumente morgen.',el:'Θα στείλω τα έγγραφα αύριο.',es:'Enviaré los documentos mañana.',et:'Saadan dokumendid homme.',fr:'Je vous enverrai les documents demain.',ga:'Seolfaidh mé na doiciméid amárach.',hr:'Poslat ću dokumente sutra.',hu:'Holnap elküldöm a dokumentumokat.',it:'Invierò i documenti domani.',lt:'Dokumentus atsiųsiu rytoj.',lv:'Es nosūtīšu dokumentus rīt.',mt:'Nibgħat id-dokumenti għada.',nl:'Ik stuur de documenten morgen.',pl:'Wyślę dokumenty jutro.',pt:'Vou enviar os documentos amanhã.',ro:'Voi trimite documentele mâine.',sk:'Pošlem dokumenty zajtra.',sl:'Dokumente bom poslal jutri.',sv:'Jag skickar dokumenten i morgon.',uk:'Я надішлю документи завтра.',ca:'Enviaré els documents demà.',nb:'Jeg sender dokumentene i morgen.',is:'Ég sendi skjölin á morgun.',sr:'Послаћу документе сутра.',bs:'Poslat ću dokumente sutra.',mk:'Ќе ги испратам документите утре.',be:'Я дашлю дакументы заўтра.',ar:'سأرسل المستندات غدًا.'};
const prior = fs.existsSync('Engine/Translation/Catalog/eu-opus-sources.json') ? JSON.parse(fs.readFileSync('Engine/Translation/Catalog/eu-opus-sources.json')) : [];
const cards = new Map(), output=[];
for (const [lang, forward, reverse, tag=''] of rows) {
  for (const [from,to,model,targetTag] of [['en',lang,forward,tag],[lang,'en',reverse,'']]) {
    if (!cards.has(model)) {
      const response=await fetch(`https://huggingface.co/Helsinki-NLP/opus-mt-${model}/raw/main/README.md`);
      if (!response.ok) throw Error(`${model}: ${response.status}`);
      const card=await response.text();
      const url=card.match(/https:\/\/object\.pouta\.csc\.fi\/[^\s)]+\.zip/)?.[0];
      if (!url || !/SentencePiece/.test(card)) throw Error(`Missing original SPM model: ${model}`);
      cards.set(model,{url,card});
    }
    const {url,card}=cards.get(model);
    output.push({pair:from+to,from,to,checkpoint:`Helsinki-NLP/opus-mt-${model}`,source_url:url,target_tag:targetTag,
      model_card_license:card.match(/^license:\s*(.+)$/m)?.[1]?.trim() ?? 'See upstream model card',
      sample_input:from==='en'?'I will send the documents tomorrow.':samples[from],
      sample_reference:to==='en'?'I will send the documents tomorrow.':samples[to],
      ...(prior.find(x=>x.pair===from+to && x.checkpoint===`Helsinki-NLP/opus-mt-${model}`)?.hf_revision ? {hf_revision:prior.find(x=>x.pair===from+to).hf_revision} : {})});
  }
}
fs.writeFileSync('Engine/Translation/Catalog/eu-opus-sources.json',JSON.stringify(output,null,2)+'\n');
console.log(`Resolved ${output.length} directions from ${cards.size} original OPUS checkpoints.`);
