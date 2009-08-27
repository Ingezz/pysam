# cython: embedsignature=True
# adds doc-strings for sphinx

# defines imported from samtools

DEF SEEK_SET = 0
DEF SEEK_CUR = 1
DEF SEEK_END = 2

## These are bits set in the flag.
## have to put these definitions here, in csamtools.pxd they got ignored
## @abstract the read is paired in sequencing, no matter whether it is mapped in a pair */
DEF BAM_FPAIRED       =1
## @abstract the read is mapped in a proper pair */
DEF BAM_FPROPER_PAIR  =2
## @abstract the read itself is unmapped; conflictive with BAM_FPROPER_PAIR */
DEF BAM_FUNMAP        =4
## @abstract the mate is unmapped */
DEF BAM_FMUNMAP       =8
## @abstract the read is mapped to the reverse strand */
DEF BAM_FREVERSE=16
## @abstract the mate is mapped to the reverse strand */
DEF BAM_FMREVERSE     =32
## @abstract this is read1 */
DEF BAM_FREAD1        =64
## @abstract this is read2 */
DEF BAM_FREAD2       =128
## @abstract not primary alignment */
DEF BAM_FSECONDARY   =256
## @abstract QC failure */
DEF BAM_FQCFAIL      =512
## @abstract optical or PCR duplicate */
DEF BAM_FDUP        =1024

#####################################################################
#####################################################################
#####################################################################
## private methods
#####################################################################

cdef samfile_t * openSam( char * filename, char * mode ):
    """open a samfile *filename*."""
    cdef samfile_t * fh
    
    fh = samopen( filename, mode, NULL)

    if fh == NULL:
        raise IOError("could not open file `%s`" % filename )

    return fh
 
cdef bam_index_t * openIndex( filename ):
    """open index for *filename*."""
    cdef bam_index_t *idx
    idx = bam_index_load(filename)

    if idx == NULL:
        raise IOError("could not open index `%s` " % filename )

    return idx


## there might a better way to build an Aligment object,
## but I could not get the following to work, usually
## getting a "can not convert to Python object"
##   1. struct to dict conversion 
##   2. using "cdef class Alignment" with __cinit__(self, bam1_t * )
DEF BAM_CIGAR_SHIFT=4
DEF BAM_CIGAR_MASK=((1 << BAM_CIGAR_SHIFT) - 1)

cdef samtoolsToAlignment( dest, bam1_t * src ):
    '''enter src into Alignment.'''

    dest.tid = src.core.tid
    dest.pos = src.core.pos
    dest.bin = src.core.bin
    dest.qual = src.core.qual
    dest.l_qname = src.core.l_qname
    dest.flag = src.core.flag
    dest.n_cigar = src.core.n_cigar
    dest.l_qseq = src.core.l_qseq
    dest.data_len = src.data_len
    dest.l_aux = src.l_aux
    dest.m_data = src.m_data

    ## for the following, see the definition on bam.h
    ## parse cigar
    cdef: 
        int op
        int l
        uint32_t* cigar_p
        uint8_t* seq_p
        uint8_t* qual_p
        int k
        char * s
        char * q

    if src.core.n_cigar > 0:
        cigar = []
        cigar_p = <uint32_t*>(src.data + src.core.l_qname)
        for k from 0 <= k < src.core.n_cigar:
            op = cigar_p[k] & BAM_CIGAR_MASK
            l = cigar_p[k] >> BAM_CIGAR_SHIFT
            cigar.append( (op,l) )
        dest.cigar = cigar
            
    ## parse qname (bam1_qname)
    dest.qname = <char*>src.data

    bam_nt16_rev_table = "=ACMGRSVTWYHKDBN"
    ## parse qseq (bam1_seq)
    if src.core.l_qseq: 
        s = <char*>calloc( src.core.l_qseq + 1 , sizeof(char) )
        seq_p = <uint8_t*>(src.data + src.core.n_cigar*4 + src.core.l_qname)
        for k from 0 <= k < src.core.l_qseq:
            ## equivalent to bam_nt16_rev_table[bam1_seqi(s, i)] (see bam.c)
            s[k] = "=ACMGRSVTWYHKDBN"[((seq_p)[(k)/2] >> 4*(1-(k)%2) & 0xf)]
        dest.qseq = s
        free(s)

    qual_p = <uint8_t*>(src.data + src.core.n_cigar*4 + src.core.l_qname + (src.core.l_qseq + 1) / 2)        
    if qual_p[0] != 0xff:
        q = <char*>calloc( src.core.l_qseq + 1 , sizeof(char) )
        for k from 0 <= k < src.core.l_qseq:
            ## equivalent to t[i] + 33 (see bam.c)
            q[k] = qual_p[k] + 33
        dest.bqual = q
        free(q)

    return dest

cdef samtoolsToPiledAlignment( dest, bam_pileup1_t * src ):
    '''fill a  PiledAlignment object from a bam_pileup1_t * object.'''
    dest.alignment = samtoolsToAlignment( Alignment(), src.b )
    dest.qpol = src.qpos
    dest.indel = src.indel
    dest.level = src.level
    dest.is_del = src.is_del
    dest.is_head = src.is_head
    dest.is_tail = src.is_tail
    return dest

#####################################################################
#####################################################################
#####################################################################
## Generic callbacks for inserting python callbacks.
#####################################################################
cdef int fetch_callback( bam1_t *alignment, void *f):
    '''callback for bam_fetch. 
    
    calls function in *f* with a new :class:`Alignment` object as parameter.
    '''
    a = samtoolsToAlignment( Alignment(), alignment )
    (<object>f)(a)

cdef int pileup_callback( uint32_t tid, uint32_t pos, int n, bam_pileup1_t *pl, void *f):
    '''callback for pileup.

    calls function in *f* with a new :class:`Pileup` object as parameter.

    tid
        chromosome ID as is defined in the header
    pos
        start coordinate of the alignment, 0-based
    n
        number of elements in pl array
    pl
        array of alignments
    data
        user provided data
    '''

    p = Pileup()
    p.tid = tid
    p.pos = pos
    p.n = n
    pileups = []

    for x from 0 <= x < n:
        pileups.append( samtoolsToPiledAlignment( PiledAlignment(), &(pl[x]) ) )
    p.pileups = pileups
        
    (<object>f)(p)

cdef int pileup_fetch_callback( bam1_t *b, void *data):
    '''callback for bam_fetch. 

    Fetches reads and submits them to pileup.
    '''
    cdef bam_plbuf_t * buf
    buf = <bam_plbuf_t*>data
    bam_plbuf_push(b, buf)
    return 0

######################################################################
######################################################################
######################################################################
## Public methods
######################################################################
cdef class Samfile:
    '''A sam file'''

    cdef samfile_t * samfile
    cdef bam_index_t *index
    cdef char * filename

    def __cinit__(self):
       self.samfile = NULL

    def isOpen( self ):
        '''return true if samfile has been opened.'''
        return self.samfile != NULL

    def hasIndex( self ):
        '''return true if samfile has an existing (and opened) index.'''
        return self.index != NULL

    def open( self, char * filename, char * mode ):
        '''open sampfile. If an index exists, it will be opened as well.'''

        ## TODO: implement automatic indexing

        if self.samfile != NULL: self.close()
        
        self.samfile = samopen( filename, mode, NULL)

        if self.samfile == NULL:
            raise IOError("could not open file `%s`" % filename )

        self.index = bam_index_load(filename)

        if self.index == NULL:
            raise IOError("could not open index `%s` " % filename )

        self.filename = filename

    def fetch(self, region, callback ):
        '''fetch a :term:`region` from the samfile.

        This method will execute a callback on each aligned read in
        a region.
        '''
        assert self.hasIndex(), "no index available for fetch"

        cdef int tid
        cdef int start
        cdef int end

        # parse the region
        bam_parse_region( self.samfile.header, region, &tid, &start, &end)
        if tid < 0:
            raise ValueError( "invalid region `%s`" % region )
        
        bam_fetch(self.samfile.x.bam, self.index, tid, start, end, <void*>callback, fetch_callback )

    def pileup( self, region, callback ):
        '''fetch a :term:`region` from the samfile and run a callback
        on each postition

        '''
        assert self.hasIndex(), "no index available for pileup"

        cdef int tid
        cdef int start
        cdef int end

        # parse the region
        bam_parse_region( self.samfile.header, region, &tid, &start, &end)
        if tid < 0: raise ValueError( "invalid region `%s`" % region )

        cdef bam_plbuf_t *buf
        buf = bam_plbuf_init(pileup_callback, <void*>callback )

        bam_fetch(self.samfile.x.bam, self.index, tid, start, end, buf, pileup_fetch_callback )

        # finalize pileup
        bam_plbuf_push( NULL, buf)
        bam_plbuf_destroy(buf);

    def close( self ):
        '''close file.'''

        if self.samfile != NULL:
            samclose( self.samfile )
            bam_index_destroy(self.index);
            self.samfile = NULL
            

## turning callbacks elegantly into iterators is an unsolved problem, see the following threads:
## http://groups.google.com/group/comp.lang.python/browse_frm/thread/0ce55373f128aa4e/1d27a78ca6408134?hl=en&pli=1
## http://www.velocityreviews.com/forums/t359277-turning-a-callback-function-into-a-generator.html
## Thus I chose to rewrite the functions requiring callbacks. The downside is that if the samtools C-API or code
## changes, the changes have to be manually entered.

cdef class IteratorRow:
    """iterate over mapped reads in a region.
    """

    cdef pair64_t * off 
    cdef bam1_t * b
    cdef uint64_t curr_off
    cdef int n_seeks
    cdef int i
    cdef int n_off 
    cdef bamFile fp
    cdef int tid
    cdef int beg
    cdef int end

    def __cinit__(self, Samfile samfile, region ):

        assert samfile.isOpen()
        assert samfile.hasIndex()

        # parse the region
        cdef int tid
        cdef int beg
        cdef int end
        bam_parse_region( samfile.samfile.header, region, &tid, &beg, &end)
        if tid < 0: raise ValueError( "invalid region `%s`" % region )

        self.tid = tid
        self.beg = beg
        self.end = end
        self.fp = samfile.samfile.x.bam
        self.n_off = pysam_bam_fetch_init( self.fp, samfile.index, self.tid, self.beg, self.end, &self.off )
        self.curr_off = 0
        self.n_seeks = 0
        self.i = -1
        self.b = <bam1_t*>calloc(1, sizeof(bam1_t))

    def __iter__(self):
        return self 

    cdef int cnext(self): 
        """C-version of iterator.next().
        
        returns 1 if the next element has been read into self.b, otherwise 0.
        """
        cdef int ret
        cdef int i 
        i = self.i

        cdef int curr_off
        cdef pair64_t * off
        cdef int n_off
        curr_off = self.curr_off
        off = self.off
        n_off = self.n_off

        if curr_off == 0 or curr_off >= off[i].v: # then jump to the next chunk
            if i == n_off - 1: return 0 # no more chunks
            if i >= 0: assert(curr_off == off[i].v) #  otherwise bug
            if i < 0 or off[i].v != off[i+1].u:
                # not adjacent chunks; then seek
                bam_seek(self.fp, off[i+1].u, SEEK_SET);
                self.curr_off = bam_tell(self.fp);
                self.n_seeks += 1
            self.i += 1

        ret = bam_read1(self.fp, self.b)
        
        if ret > 0:
            self.curr_off = bam_tell(self.fp)
            if (self.b.core.tid != self.tid or self.b.core.pos >= self.end):
                return 0 # no need to proceed
            else:
                if pysam_bam_fetch_is_overlap(self.beg, self.end, self.b):
                    return 1
        else:
            return 0

    cdef bam1_t * getCurrent( self ):
        return self.b
    
    def __next__(self): 
        """python version of next().

        pyrex uses this non-standard name instead of next()
        """
        cdef int ret
        ret = self.cnext()

        if ret > 0 :
            return samtoolsToAlignment( Alignment(), self.b )
        else:
            raise StopIteration

    def __dealloc__(self):
        '''remember: dealloc cannot call other methods!'''
        bam_destroy1( self.b )
        free( <void*>self.off )


cdef class IteratorColumn:
    '''iterate over columns.

    This iterator wraps the pileup functionality of the samtools
    function bam_plbuf_push.
    '''
    cdef bam_plbuf_t *buf

    # check if first iteration
    cdef int notfirst
    cdef int n_pu
    cdef int eof 
    cdef IteratorRow iter

    def __cinit__(self, Samfile samfile, region ):

        self.iter = IteratorRow( samfile, "seq1:10-20")
        self.buf = bam_plbuf_init(NULL, NULL )
        self.n_pu = 0
        self.eof = 0

    def __iter__(self):
        return self 

    cdef int cnext(self):

        cdef int retval1, retval2

        # check if previous plbuf was incomplete. If so, continue within
        # the loop and yield if necessary
        if self.n_pu > 0:
            self.n_pu = pysam_bam_plbuf_push( self.iter.getCurrent(), self.buf, 1)
            if self.n_pu > 0: return 1

        if self.eof: return 0

        # get next alignments and submit until plbuf indicates that
        # an new column has finished
        while self.n_pu == 0:
            retval1 = self.iter.cnext()
            # wrap up if no more input
            if retval1 == 0: 
                self.n_pu = pysam_bam_plbuf_push( NULL, self.buf, 0)            
                self.eof = 1
                return 1

            # submit to plbuf
            self.n_pu = pysam_bam_plbuf_push( self.iter.getCurrent(), self.buf, 0)            
            if self.n_pu < 0: raise ValueError( "error while iterating" )

        # plbuf has yielded
        return 1

    def __next__(self): 
        """python version of next().

        pyrex uses this non-standard name instead of next()
        """
        cdef int ret
        ret = self.cnext()
        cdef bam_pileup1_t * pl

        if ret > 0 :
            p = Pileup()
            p.tid = pysam_get_tid( self.buf )
            p.pos = pysam_get_pos( self.buf )
            p.n = self.n_pu
            pl = pysam_get_pileup( self.buf )

            pileups = []
            
            for x from 0 <= x < p.n:
                pileups.append( samtoolsToPiledAlignment( PiledAlignment(), &pl[x]) )
            p.pileups = pileups

            return p
        else:
            raise StopIteration

    def __dealloc__(self):
        bam_plbuf_destroy(self.buf);

class Alignment(object):
    '''
    Python wrapper around an aligned read. The following
    fields are exported:

    tid
        chromosome/target ID
    pos
        0-based leftmost coordinate
    bin
        bin calculated by bam_reg2bin()
    qual
        mapping quality
    l_qname
        length of the query name
    flag
        bitwise flag
    n_cigar
        number of CIGAR operations
    l_qseq
        length of the query sequence (read)
    qname
        the query name (None if not present)
    cigar
        the :term:`cigar` alignment string (None if not present)
    qseq
        the query sequence (None if not present)
    bqual
        the base quality (None if not present)
    '''

    tid = 0
    pos = 0
    bin = 0
    qual = 0
    l_qname = 0
    flag = 0
    n_cigar = 0
    l_qseq = 0
    qname = None
    cigar = None
    qseq = None
    bqual = None

    def __init__(self, **kwargs):
        self.tid = kwargs.get("tid",0)
        self.pos = kwargs.get("pos",0)
        self.bin = kwargs.get("bin",0)
        self.qual = kwargs.get("qual",0)
        self.l_qname = kwargs.get("l_qname",0)
        self.flag = kwargs.get("flag",0)
        self.n_cigar = kwargs.get("n_cigar",0)
        self.l_qseq = kwargs.get("l_qseq",0)
        self.qname = kwargs.get("qname", None)
        self.cigar = kwargs.get("cigar", None)
        self.qseq = kwargs.get("qseq", None)
        self.qual = kwargs.get("qual", None)
        self.bqual = kwargs.get("bqual", None)

    def __str__(self):
        return "\t".join( map(str, (self.qname,
                                    self.tid,
                                    self.pos,
                                    self.bin,
                                    self.qual,
                                    self.l_qname,
                                    self.flag, 
                                    self.n_cigar,
                                    self.l_qseq,
                                    self.qseq,
                                    self.cigar,
                                    self.bqual, ) ) )

    # @abstract the read is paired in sequencing, no matter whether it is mapped in a pair */
    def _getfpaired( self ): return (self.fpaired & BAM_FPAIRED) != 0
    is_paired = property( _getfpaired, doc="true if read is paired in sequencing" )
    def _getfproper_pair( self ): return (self.flag & BAM_FPROPER_PAIR) != 0
    is_proper_pair = property( _getfproper_pair, doc="true if read is mapped in a proper pair" )
    def _getfunmap( self ): return (self.flag & BAM_FUNMAP) != 0
    is_unmapped = property( _getfunmap, doc="true if read itself is unmapped" )
    def _getfmunmap( self ): return (self.flag & BAM_FMUNMAP) != 0
    mate_is_unmapped = property( _getfmunmap, doc="true if the mate is unmapped" )
    def _getreverse( self ): return (self.flag & BAM_FREVERSE) != 0
    is_reverse = property( _getreverse, doc = "true if read is mapped to reverse strand" )
    def _getmreverse( self ): return (self.flag & BAM_FMREVERSE) != 0
    mate_is_reverse = property( _getmreverse, doc= "true is read is mapped to reverse strand" )
    def _getread1( self ): return (self.flag & BAM_FREAD1) != 0
    is_read1 = property( _getread1, doc = "true if this is read1" )
    def _getread2( self ): return (self.flag & BAM_FREAD2) != 0
    is_read2 = property( _getread2, doc = "true if this is read2" )
    def _getfsecondary( self ): return (self.flag & BAM_FSECONDARY) != 0
    is_secondary = property( _getfsecondary, doc="true if not primary alignment" )
    def _getfqcfail( self ): return (self.flag & BAM_FSECONDARY) != 0
    is_qcfail = property( _getfqcfail, doc="true if QC failure" )
    def _getfdup( self ): return (self.flag & BAM_FDUP) != 0
    is_duplicate = property( _getfdup, doc="true if optical or PCR duplicate" )

class Pileup(object):
    '''container for piled-up alignments.

    tid
        chromosome ID as is defined in the header
    pos
        start coordinate of the alignment, 0-based
    n
        number of reads in mapped reads pileup
    pileups
        piled up alignments
    '''
    def __str__(self):
        return "\t".join( map(str, (self.tid, self.pos, self.n))) +\
            "\n" +\
            "\n".join( map(str, self.pileups) )

class PiledAlignment(object):
    '''A piled alignment.

    alignment
       a class:`Alignment` object of the aligned read
    qpos
       position of the read base at the pileup site, 0-based
    indel
       indel length; 0 for no indel, positive for ins and negative for del
    is_del
       1 iff the base on the padded read is a deletion
    level
       the level of the read in the "viewer" mode 
    '''

    def __init__(self, **kwargs ):
        
        ## there must be an easier way to construct this class, but it won't accept
        ## a typed parameter.
        self.alignment = kwargs.get( "alignment", Alignment() )
        self.qpos = kwargs.get("qpos", 0)
        self.indel = kwargs.get("indel", 0)
        self.level = kwargs.get("level", 0)
        self.is_del = kwargs.get("is_del", 0)
        self.is_head = kwargs.get("is_head", 0)
        self.is_tail = kwargs.get("is_tail", 0)

    def __str__(self):
        return "\t".join( map(str, (self.alignment, self.qpos, self.indel, self.level, self.is_del, self.is_head, self.is_tail ) ) )

__all__ = ["Samfile", "IteratorRow", "IteratorColumn", "Alignment", "Pileup", "PiledAlignment" ]

