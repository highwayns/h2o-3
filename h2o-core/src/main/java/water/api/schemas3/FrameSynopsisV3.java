package water.api.schemas3;

import water.Iced;
import water.api.API;
import water.api.schemas3.KeyV3.FrameKeyV3;
import water.fvec.Frame;
import water.fvec.VecAry;

/**
 * The minimal amount of information on a Frame.
 * @see water.api.FramesHandler#list(int, FramesV3)
 */
public class FrameSynopsisV3 extends FrameBaseV3<Iced, FrameSynopsisV3> {

  public FrameSynopsisV3() {}

  // Output fields
  @API(help="Number of rows in the Frame", direction=API.Direction.OUTPUT)
  public long rows;

  @API(help="Number of columns in the Frame", direction=API.Direction.OUTPUT)
  public long columns;

  public FrameSynopsisV3(Frame fr) {
    VecAry vecs = fr.vecs();
    frame_id = new FrameKeyV3(fr._key);
    _fr = fr;
    rows = fr.numRows();
    columns = vecs.len();
    byte_size = vecs.byteSize();
    is_text = vecs.isRawBytes();
  }
}