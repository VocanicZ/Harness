import json,glob,os,sys
root='bench/results/run-20261116-large-plain/plain.runs'
out={}
for i in (1,2,3):
    r={'main':None,'subagents':[]}
    for f in sorted(glob.glob(f'{root}/run-0{i}.logs/transcripts/**/*.jsonl',recursive=True)):
        peak=0;turns=0;comp=0
        for line in open(f,encoding='utf-8',errors='replace'):
            try: e=json.loads(line)
            except Exception: continue
            if e.get('isCompactSummary') or (e.get('type')=='system' and e.get('subtype')=='compact_boundary'): comp+=1
            u=(e.get('message') or {}).get('usage') if isinstance(e.get('message'),dict) else None
            if u and e.get('type')=='assistant':
                c=(u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0))
                peak=max(peak,c);turns+=1
        rec={'file':os.path.relpath(f,root),'peak_context_tokens':peak,'assistant_turns':turns,'compact_markers':comp}
        if '/subagents/' in f: r['subagents'].append(rec)
        else: r['main']=rec
    out[f'run-0{i}']=r
json.dump(out,open('bench/results/run-20261116-large-plain/peak-context.json','w'),indent=1)
for k,v in out.items():
    sub=[s for s in v['subagents']]
    m=v['main'];sp=[x['peak_context_tokens'] for x in v['subagents']]
    print(k,m['peak_context_tokens'],m['assistant_turns'],m['compact_markers'],'subagents',len(sp),max(sp or [0]))
