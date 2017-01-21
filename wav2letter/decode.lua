require 'torch'

torch.setdefaulttensortype('torch.FloatTensor')
torch.manualSeed(1111)

local cmd = torch.CmdLine()
cmd:text()
cmd:text('SpeechRec (c) Ronan Collobert 2015')
cmd:text()
cmd:text('Arguments:')
cmd:argument('-dir', 'directory with output/sentence archives')
cmd:argument('-name', 'name of the pair to decode')
cmd:text()
cmd:text('Options:')
cmd:option('-maxload', -1, 'max number of testing examples')
cmd:option('-show', false, 'show predictions')
cmd:option('-showletters', false, 'show letter predictions')
cmd:option('-letters', "", 'letters.lst')
cmd:option('-words', "", 'words.lst')
cmd:option('-maxword', -1, 'maximum number of words to use')
cmd:option('-lm', "", 'lm.arpa.bin')
cmd:option('-smearing', "none", 'none, max or logadd')
cmd:option('-lmweight', 1, 'lm weight')
cmd:option('-wordscore', 0, 'word insertion weight')
cmd:option('-unkscore', -math.huge, 'unknown (word) insertion weight')
cmd:option('-beamsize', 25000, 'max beam size')
cmd:option('-beamscore', 40, 'beam score threshold')
cmd:option('-forceendsil', false, 'force end sil')
cmd:option('-logadd', false, 'use logadd instead of max')
cmd:option('-nthread', 0, 'number of threads to use')
cmd:option('-sclite', false, 'output sclite format')
cmd:text()

local testopt = cmd:parse(arg)

local function test(opt, slice, nslice)
   local tnt = require 'torchnet'
   require 'wav2letter'

   local decoder = paths.dofile('decoder.lua')
   decoder = decoder(
      opt.letters,
      opt.words,
      opt.lm,
      opt.smearing,
      opt.maxword
   )

   local __unknowns = {}
   local function string2tensor(str)
      local words = decoder.words
      local t = {}
      for word in str:gmatch('(%S+)') do
         if not words[word] then
            if not __unknowns[word] then
               __unknowns[word] = true
               print(string.format('$ warning: unknown word <%s>', word))
            end
         end
         table.insert(t, words[word] and words[word].idx or #words+1)
      end
      return torch.LongTensor(t)
   end

   local function tensor2string(t)
      if t:nDimension() == 0 then
         return ""
      end
      local words = decoder.words
      local str = {}
      for i=1,t:size(1) do
         local word = words[t[i]].word
         assert(word)
         table.insert(str, word)
      end
      return table.concat(str, ' ')
   end

   local function tensor2letterstring(t)
      if t:nDimension() == 0 then
         return ""
      end
      local letters = decoder.letters
      local str = {}
      for i=1,t:size(1) do
         local letter = letters[t[i]]
         assert(letter)
         table.insert(str, letter)
      end
      return table.concat(str)
   end

   local fout = tnt.IndexedDatasetReader{
      indexfilename = string.format("%s/output-%s.idx", opt.dir, opt.name),
      datafilename  = string.format("%s/output-%s.bin", opt.dir, opt.name),
      mmap = true,
      mmapidx = true,
   }
   local transitions = torch.DiskFile(string.format("%s/transitions-%s.bin", opt.dir, opt.name)):binary():readObject()

   local wer = tnt.EditDistanceMeter()
   local iwer = tnt.EditDistanceMeter()
   local n1 = 1
   local n2 = opt.maxload > 0 and opt.maxload or fout:size()
   local timer = torch.Timer()

   if slice and nslice then
      local nperslice = math.ceil((n2-n1+1)/nslice)
      n1 = (slice-1)*nperslice+1
      if n1 > n2 then
         n1 = 1 -- beware
         n2 = 0
         print(string.format('[slice %d/%d doing nothing]', slice, nslice))
      else
         n2 = math.min(n1+nperslice-1, n2)
         print(string.format('[slice %d/%d going from %d to %d]', slice, nslice, n1, n2))
      end
   end

   local dopt = {
      lmweight = opt.lmweight,
      wordscore = opt.wordscore,
      unkscore = opt.unkscore,
      beamsize = opt.beamsize,
      beamscore = opt.beamscore,
      forceendsil = opt.forceendsil,
      logadd = opt.logadd
   }

   local sentences = {}
   for i=n1,n2 do
      local prediction = fout:get(i)
      local targets = prediction.words
      local emissions = prediction.output
      local predictions, lpredictions = decoder(dopt, transitions, emissions)
      -- remove <unk>
      predictions = string2tensor(tensor2string(predictions):gsub("%<unk%>", ""))
      do
         local targets = string2tensor(targets)
         iwer:reset()
         iwer:add(predictions, targets)
         wer:add(predictions, targets)
      end
      if opt.show then
         print(
            string.format(
               "%06d |P| %s\n%06d |T| %s {progress=%03d%% iWER=%06.2f%% sliceWER=%06.2f%%}",
               i,
               tensor2string(predictions),
               i,
               targets:gsub("^%s+", ""):gsub("%s+$", ""),
               n1 == n2 and 100 or (i-n1)/(n2-n1)*100,
               iwer:value(),
               wer:value()
            )
         )
         sentences[i] = {ref=targets:gsub("^%s+", ""):gsub("%s+$", ""), hyp=tensor2string(predictions)}
      end
      if opt.showletters then
         print(
            string.format(
               "%06d |L| \"%s\"",
               i,
               tensor2letterstring(lpredictions)
            )
         )
      end
   end
   print(string.format("[Memory usage: %.2f Mb]", decoder.decoder:mem()/2^20))
   return wer.sum, wer.n, n2-n1+1, sentences, timer:time().real
end

local totalacc = 0
local totaln = 0
local totalseq = 0
local totaltime = 0

local timer = torch.Timer()
local sentences = {}

if testopt.nthread <= 0 then
   totalacc, totaln, totalseq, sentences, totaltime = test(testopt)
else
   local threads = require 'threads'
   local pool = threads.Threads(testopt.nthread)
   for i=1,testopt.nthread do
      pool:addjob(
         function()
            return test(testopt, i, testopt.nthread)
         end,
         function(acc, n, seq, subsentences, time)
            totalacc = totalacc + acc
            totaln = totaln + n
            totalseq = totalseq + seq
            totaltime = totaltime + time
            for i, p in pairs(subsentences) do
               assert(not sentences[i])
               sentences[i] = p
            end
         end
      )
   end
   pool:synchronize()
end

print(string.format("[Decoded %d sequences in %.2f s (actual: %.2f s)]", totalseq, timer:time().real, totaltime))
print(string.format("[WER on %s = %03.2f%%]", testopt.name, totalacc/totaln*100))

if testopt.sclite then
   local fhyp = io.open(string.format("%s/sclite-%s.hyp", testopt.dir, testopt.name), "w")
   local fref = io.open(string.format("%s/sclite-%s.ref", testopt.dir, testopt.name), "w")
   for i, p in ipairs(sentences) do
      fhyp:write(string.format("%s (SPEAKER_%05d)\n", p.hyp, i))
      fref:write(string.format("%s (SPEAKER_%05d)\n", p.ref, i))
   end
end
