/*  Boolector: Satisfiability Modulo Theories (SMT) solver.
 *
 *  Copyright (C) 2007-2021 by the authors listed in the AUTHORS file.
 *
 *  This file is part of Boolector.
 *  See COPYING for more information on using this software.
 */

/*------------------------------------------------------------------------*/
#ifdef BTOR_USE_IPASIR
/*------------------------------------------------------------------------*/

#include "btorcore.h"
#include "btorabort.h"
#include "sat/btoripasir.h"
#include "ipasir.h"

int adds = 0;
int assumes = 0;
int vals = 0;
int fails = 0;

static void *
init (BtorSATMgr *smgr)
{
  void *res;

  BTOR_MSG (smgr->btor->msg, 1, "Ipasir solver %s", ipasir_signature());

  res = ipasir_init();
  return res;
}

static void
add (BtorSATMgr *smgr, int32_t lit)
{
  adds++;
  (void) ipasir_add (smgr->solver, lit);
}

static int32_t
sat (BtorSATMgr *smgr, int32_t limit)
{
  (void) limit;
  printf("=== Calling solver after %d adds %d assumes %d vals and %d fails ===\n", adds, assumes, vals, fails);
  int sres = ipasir_solve (smgr->solver);
  printf("=== Sat solver return result %d ===\n", sres);
	return sres;
}

static int32_t
deref (BtorSATMgr *smgr, int32_t lit)
{
  vals++;
  int rval =  ipasir_val (smgr->solver, lit) > 0 ? 1 : -1;
  //printf("=== val on %d returned %d ===\n", lit, rval);
  return rval;
}

static void
reset (BtorSATMgr *smgr)
{
  ipasir_release (smgr->solver);
  smgr->solver = 0;
}

static void
assume (BtorSATMgr *smgr, int32_t lit)
{
  assumes++;
  (void) ipasir_assume (smgr->solver, lit);
}

static int32_t
failed (BtorSATMgr *smgr, int32_t lit)
{
  fails++;
  return ipasir_failed (smgr->solver, lit);
}

/*------------------------------------------------------------------------*/

bool
btor_sat_enable_ipasir (BtorSATMgr *smgr)
{
  assert (smgr != NULL);

  BTOR_ABORT (smgr->initialized,
              "'btor_sat_init' called before 'btor_sat_enable_picosat'");

  smgr->name = "PicoSAT";

  BTOR_CLR (&smgr->api);
  smgr->api.add              = add;
  smgr->api.assume           = assume;
  smgr->api.deref            = deref;
  smgr->api.enable_verbosity = 0;
  smgr->api.failed           = failed;
  smgr->api.fixed            = 0;
  smgr->api.inc_max_var      = 0;
  smgr->api.init             = init;
  smgr->api.melt             = 0;
  smgr->api.repr             = 0;
  smgr->api.reset            = reset;
  smgr->api.sat              = sat;
  smgr->api.set_output       = 0;
  smgr->api.set_prefix       = 0;
  smgr->api.stats            = 0;
  return true;
}
/*------------------------------------------------------------------------*/
#endif
/*------------------------------------------------------------------------*/
