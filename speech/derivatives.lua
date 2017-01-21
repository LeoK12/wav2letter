local speech = require('libspeech')

--Appends double deltas (derivatives + acceleration) to input frames
--Expect 2d tensor of frames
--See: http://www1.icsi.berkeley.edu/Speech/docs/HTKBook/node65_mn.html
local function Derivatives(deltawindow, accwindow)
   deltawindow = deltawindow or 0
   accwindow = accwindow or 0
   return function(output_raw, input_raw)
      local input, output = speech.Proc(output_raw, input_raw)
      output:resize(input:size(1), 3*input:size(2))
      input.speech.Derivatives_forward(deltawindow, accwindow,
                                       input,       output)
      return output
   end
end

speech.Derivatives = Derivatives
